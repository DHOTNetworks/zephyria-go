package core

import (
	"fmt"
	"math/big"
	"sync"
	"zephyria/state"
	ztypes "zephyria/types" // Zephyria types

	zvm "zephyria/vm"

	"github.com/ethereum/go-ethereum/common"
	ethcore "github.com/ethereum/go-ethereum/core" // Alias to avoid conflict
	"github.com/ethereum/go-ethereum/core/types"   // Geth types
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

// Executor manages EVM execution.
type Executor struct {
	config *params.ChainConfig
	netCfg *NetworkConfig
	bc     interface { // Minimal interface to avoid cyclic import if possible, or use *Blockchain if same package (no, bc is in core too)
		GetBlockByNumber(uint64) *ztypes.Block
	}
}

// But wait, core/blockchain.go is in package core.
// Executor is in package core.
// So we can just use *Blockchain.

var (
	StakingAddr = common.HexToAddress("0x0000000000000000000000000000000000001000") // Fallback
	RewardAddr  = common.HexToAddress("0x0000000000000000000000000000000000002000") // Fallback
)

// NewExecutor creates a new Executor.
func NewExecutor(config *params.ChainConfig, netCfg *NetworkConfig, bc *Blockchain) *Executor {
	return &Executor{config: config, netCfg: netCfg, bc: bc}
}

// ApplyBlock executes transactions in a block and returns the receipts and new root.
func (e *Executor) ApplyBlock(statedb *state.StateDB, header *ztypes.Header, txs []*types.Transaction) ([]*ztypes.Receipt, common.Hash, error) {
	// 1. Sealevel Scheduler: Group txs into non-conflicting waves
	waves := e.schedule(txs)

	// 2. Parallel Execution
	var waveWg sync.WaitGroup
	var mergeLock sync.Mutex // Serialize merges to parent state

	// Track block-level limits
	blockGasUsed := uint64(0)
	totalFees := new(big.Int) // Accumulate fees

	// Receipts need to be ordered same as txs.
	// Map: TxHash -> Receipt, then reconstruction? Or just append in order?
	// Since we execute in waves, we can just collect all then sort?
	// Or simpler: Pre-allocate slice? But we filter out invalid txs/oversized?
	// If we filter, the block shouldn't contain them?
	// For PoC, let's assume valid blocks.

	receipts := make([]*ztypes.Receipt, len(txs))

	// Map tx hash to index for placement
	txIndex := make(map[common.Hash]int)
	for i, tx := range txs {
		txIndex[tx.Hash()] = i
	}

	for _, wave := range waves {
		// Validate against Block Gas Limit (60M)
		if blockGasUsed > 60_000_000 {
			break
		}

		waveWg.Add(len(wave))

		// For each independent sub-group in the wave, we could run parallel.
		// My scheduler (below) returns "waves" where verify EVERY tx in the wave is independent of others in the same wave.
		// So we can run ALL txs in this wave in parallel.

		for _, tx := range wave {
			go func(tx *types.Transaction) {
				defer waveWg.Done()

				// Enforce Tx Size Limit (Zephyria PoC: 512KB)
				if tx.Size() > 512*1024 {
					return
				}

				// Create isolated overlay state
				overlayDB := statedb.NewOverlay()

				// Prepare EVM
				// Prepare state (on overlay)
				rules := e.config.Rules(header.Number, true, header.Time)
				msg, err := ethcore.TransactionToMessage(tx, types.LatestSigner(e.config), header.BaseFee)
				if err != nil {
					return
				}

				// Enforce Account Gas Limit (simplified: Check limit logic would go here,
				// but requires tracking usage across blocks. For PoC, we skip complex account tracking)

				// Pass AccessList and Destination to Prepare
				overlayDB.Prepare(rules, msg.From, header.Coinbase, msg.To, vm.ActivePrecompiles(rules), msg.AccessList)

				// Use Local Zephyria VM Wrapper
				getHash := func(n uint64) common.Hash {
					if header.Number.Uint64() > n && header.Number.Uint64()-n <= 256 {
						if e.bc != nil {
							block := e.bc.GetBlockByNumber(n)
							if block != nil {
								return block.Hash()
							}
						}
					}
					return common.Hash{}
				}

				// Create EVM via zvm package
				// Using Geth Header type for compatibility in wrapper, or constructing block context manually if wrapper allows?
				// Wrapper takes *types.Header (Geth). We have *ztypes.Header.
				// We need to convert or adapt.
				// For now, let's keep it simple: Wrapper accepts specific fields or we cast.
				// Actually, ztypes.Header has exact same fields?
				// Let's modify zvm to take config explicitly if headers mismatch.
				// Or... Executor has ztypes.Header.
				// Let's check imports in zephyria/vm/evm.go. It uses "github.com/ethereum/go-ethereum/core/types".
				// ztypes is "zephyria/types".
				// They are likely compatible structs but different types.
				// I should cast or fill a Geth header.

				// Define isSystemTx for gas refund logic
				stakingAddr := e.netCfg.Params.StakingAddr
				rewardAddr := e.netCfg.Params.RewardAddr
				validatorAddr := e.netCfg.Params.ValidatorAddr
				isSystemTx := msg.To != nil && (*msg.To == stakingAddr || *msg.To == rewardAddr || *msg.To == validatorAddr)

				gethHeader := &types.Header{
					ParentHash:  header.ParentHash,
					UncleHash:   types.EmptyUncleHash, // Zephyria doesn't use Uncles
					Coinbase:    header.Coinbase,
					Root:        header.VerkleRoot,   // Map VerkleRoot to Root
					TxHash:      types.EmptyRootHash, // Not tracked in header in same way? Or we don't have it accessable here easily
					ReceiptHash: types.EmptyRootHash,
					Bloom:       types.Bloom{},
					Difficulty:  header.Difficulty,
					Number:      header.Number,
					GasLimit:    header.GasLimit,
					GasUsed:     header.GasUsed,
					Time:        header.Time,
					Extra:       header.ExtraData,
					MixDigest:   common.Hash{},      // No PoW
					Nonce:       types.BlockNonce{}, // No PoW
					BaseFee:     header.BaseFee,
				}

				evm := zvm.New(gethHeader, e.config, overlayDB, getHash)

				gp := new(ethcore.GasPool)
				gp.AddGas(header.GasLimit)

				// Execute via Wrapper
				res, err := evm.ApplyMessage(msg, gp)
				if err != nil {
					// Even on error, we must produce a receipt to keep indices aligned
					fmt.Printf(" [!] Block execution error for tx %s: %v\n", tx.Hash().Hex(), err)
					idx := txIndex[tx.Hash()]
					receipts[idx] = &ztypes.Receipt{
						TxHash:  tx.Hash(),
						Status:  0,
						GasUsed: 0,
					}
					return
				}

				if res.Failed() {
					fmt.Printf(" [!] Tx %s failed: %v\n", tx.Hash().Hex(), res.Err)
				}

				// If system tx, refund gas and skip fee deduction in final merge
				if isSystemTx {
					res.UsedGas = 0
				}

				// ---------------------------------------------------------
				// SYSTEM CONTRACTS
				// ---------------------------------------------------------
				// Pass Coinbase for checks? For now simplified.
				e.ProcessSystemContracts(overlayDB, msg, tx, nil) // Header config not needed for basics
				mergeLock.Lock()
				overlayDB.Merge()
				blockGasUsed += res.UsedGas // Track total gas

				// Calculate Fee
				gasPrice := tx.GasPrice()
				if header.BaseFee != nil {
					// Effective = min(GasFeeCap, BaseFee + TipCap)
					priority := new(big.Int).Add(header.BaseFee, tx.GasTipCap())
					if priority.Cmp(gasPrice) < 0 {
						gasPrice = priority
					}
				}
				fee := new(big.Int).Mul(new(big.Int).SetUint64(res.UsedGas), gasPrice)
				totalFees.Add(totalFees, fee)

				// Create Receipt
				idx := txIndex[tx.Hash()]
				receipt := &ztypes.Receipt{
					TxHash:            tx.Hash(),
					GasUsed:           res.UsedGas,
					CumulativeGasUsed: blockGasUsed, // Approx, since parallel
					Logs:              overlayDB.GetLogs(tx.Hash()),
					Status:            status(res.Failed()), // 1 success, 0 fail
				}
				if msg.To == nil {
					receipt.ContractAddress = crypto.CreateAddress(msg.From, tx.Nonce())
				}
				receipts[idx] = receipt

				mergeLock.Unlock()
			}(tx)
		}
		waveWg.Wait()
	}

	// -------------------------------------------------------------
	// ECONOMICS: Block Rewards & Fees
	// -------------------------------------------------------------
	// 1. Block Reward: Fixed 10 ZEE
	// 2. Tx Fees: Sum of (GasUsed * EffectiveGasPrice)

	reward := new(big.Int).SetUint64(10_000_000_000_000_000_000) // 10 ZEE

	// Add accumulated fees (tracked in totalFees during execution)
	reward.Add(reward, totalFees)

	statedb.AddBalanceReward(header.Coinbase, uint256.MustFromBig(reward))
	// fmt.Printf("Miner %s rewarded %s zei (Gas: %d)\n", header.Coinbase.Hex(), reward, blockGasUsed)

	// Compact Receipts (remove nils from skipped txs)
	// IMPORTANT: Every transaction in a block MUST have a receipt to keep indices aligned.
	finalReceipts := make([]*ztypes.Receipt, 0)
	cumulative := uint64(0)
	for i, r := range receipts {
		if r == nil {
			// This shouldn't happen if miners filter correctly, but for robustness:
			// Add a failed receipt for the missing index.
			r = &ztypes.Receipt{
				TxHash:  txs[i].Hash(),
				Status:  0,
				GasUsed: 0,
			}
		}
		cumulative += r.GasUsed
		r.CumulativeGasUsed = cumulative
		finalReceipts = append(finalReceipts, r)
	}

	// In Verkle, we return the new Root.
	return finalReceipts, statedb.IntermediateRoot(false), nil
}

func status(failed bool) uint64 {
	if failed {
		return 0
	}
	return 1
}

// Schedule logic moved to scheduler.go

// Call executes a message call for simulation (eth_call, eth_estimateGas) without committing state.
func (e *Executor) Call(statedb *state.StateDB, header *ztypes.Header, msg *ethcore.Message) (*ethcore.ExecutionResult, error) {
	// Create isolated overlay state
	overlayDB := statedb.NewOverlay()

	// Prepare EVM
	rules := e.config.Rules(header.Number, true, header.Time)

	// Ensure context (Coinbase, Time, etc) matches the header provided (usually pending or latest)
	getHash := func(n uint64) common.Hash { return common.Hash{} }

	overlayDB.Prepare(rules, msg.From, header.Coinbase, msg.To, vm.ActivePrecompiles(rules), msg.AccessList)

	// Convert Header
	gethHeader := &types.Header{
		ParentHash:  header.ParentHash,
		UncleHash:   types.EmptyUncleHash,
		Coinbase:    header.Coinbase,
		Root:        header.VerkleRoot,
		TxHash:      types.EmptyRootHash,
		ReceiptHash: types.EmptyRootHash,
		Bloom:       types.Bloom{},
		Difficulty:  header.Difficulty,
		Number:      header.Number,
		GasLimit:    header.GasLimit,
		GasUsed:     header.GasUsed,
		Time:        header.Time,
		Extra:       header.ExtraData,
		MixDigest:   common.Hash{},
		Nonce:       types.BlockNonce{},
		BaseFee:     header.BaseFee,
	}

	evm := zvm.New(gethHeader, e.config, overlayDB, getHash)

	gp := new(ethcore.GasPool)
	gp.AddGas(header.GasLimit)

	// Execute
	return evm.ApplyMessage(msg, gp)
}
