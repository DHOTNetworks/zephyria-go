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
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types" // Geth types
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
	validatorRegistry *OnChainValidatorRegistry
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
	return &Executor{
		config:            config,
		netCfg:            netCfg,
		bc:                bc,
		validatorRegistry: NewOnChainValidatorRegistry(netCfg.Params.StakingAddr, netCfg.Params.ValidatorAddr),
	}
}

// GetValidatorRegistry returns the internal validator registry.
func (e *Executor) GetValidatorRegistry() *OnChainValidatorRegistry {
	return e.validatorRegistry
}

// getProductionConfig returns a hardcoded config with all forks enabled to ensure correct EVM behavior.
// This decouples execution from potentially fragile genesis configurations.
func getProductionConfig(chainID *big.Int) *params.ChainConfig {
	return &params.ChainConfig{
		ChainID:                 chainID,
		HomesteadBlock:          big.NewInt(0),
		DAOForkBlock:            big.NewInt(0),
		EIP150Block:             big.NewInt(0),
		EIP155Block:             big.NewInt(0),
		EIP158Block:             big.NewInt(0),
		ByzantiumBlock:          big.NewInt(0),
		ConstantinopleBlock:     big.NewInt(0),
		PetersburgBlock:         big.NewInt(0),
		IstanbulBlock:           big.NewInt(0),
		MuirGlacierBlock:        big.NewInt(0),
		BerlinBlock:             big.NewInt(0),
		LondonBlock:             big.NewInt(0),
		ArrowGlacierBlock:       nil,
		GrayGlacierBlock:        nil,
		MergeNetsplitBlock:      nil,
		ShanghaiTime:            new(uint64),   // ENABLED
		CancunTime:              new(uint64),   // ENABLED
		TerminalTotalDifficulty: big.NewInt(0), // FORCE POS
	}
}

// ApplyBlock executes transactions in a block and returns the receipts and new root.
func (e *Executor) ApplyBlock(statedb *state.StateDB, header *ztypes.Header, txs []*types.Transaction) ([]*ztypes.Receipt, common.Hash, error) {
	// 1. Aquarius Scheduler: Group txs into non-conflicting waves
	waves := e.schedule(txs, statedb)

	// 2. Atomic Execution Context
	// We use an overlay for the entire block so that partial failures (or verification failures)
	// do not corrupt the main state.
	blockState := statedb.NewOverlay()

	// 2. Parallel Execution
	var waveWg sync.WaitGroup

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

	var fatalErr error

	// FORCE PRODUCTION CONFIG
	evmConfig := getProductionConfig(e.config.ChainID)

	type WaveResult struct {
		Overlay *state.StateDB
		GasUsed uint64
		Receipt *ztypes.Receipt
		Fee     *big.Int
		Err     error
		Tx      *types.Transaction
	}

	for _, wave := range waves {
		// Validate against Block Gas Limit (60M)
		if blockGasUsed > 60_000_000 {
			break
		}

		// Optimization: If wave has 1 tx, avoid secondary overlay overhead
		if len(wave) == 1 {
			tx := wave[0]
			msg, err := ethcore.TransactionToMessage(tx, types.LatestSigner(e.config), header.BaseFee)
			if err != nil {
				fatalErr = err
				break
			}

			// Aquarius Auto-Binding: Redirect to Data Shard if targeting a Program
			// EXCEPTION: Native Token Program manages its own sharding via SSTORE/SLOAD interception.
			if msg.To != nil {
				// DEBUG EXECUTOR
				fmt.Printf("DEBUG: Exec Tx To: %s | TokenProgramID: %s | Equal: %v\n", msg.To.Hex(), state.TokenProgramID.Hex(), *msg.To == state.TokenProgramID)
			}
			if msg.To != nil && *msg.To != state.TokenProgramID {
				if owner := blockState.GetProgramAddress(*msg.To); owner != state.TokenProgramID {
					dataCtx, _, redirected := blockState.ResolveExecutionTarget(msg.From, *msg.To)
					if redirected {
						fmt.Printf("DEBUG: Redirecting %s -> %s\n", msg.To.Hex(), dataCtx.Hex())
						msg.To = &dataCtx
					}
				}
			}

			rules := evmConfig.Rules(header.Number, true, header.Time)
			blockState.Prepare(rules, msg.From, header.Coinbase, msg.To, vm.ActivePrecompiles(rules), msg.AccessList)

			gethHeader := &types.Header{
				ParentHash:  header.ParentHash,
				UncleHash:   types.EmptyUncleHash,
				Coinbase:    header.Coinbase,
				Root:        header.VerkleRoot,
				TxHash:      types.EmptyRootHash,
				ReceiptHash: types.EmptyRootHash,
				Bloom:       types.Bloom{},
				Difficulty:  big.NewInt(0),
				Number:      header.Number,
				GasLimit:    header.GasLimit,
				GasUsed:     header.GasUsed,
				Time:        header.Time,
				Extra:       header.ExtraData,
				MixDigest:   common.Hash{},
				Nonce:       types.BlockNonce{},
				BaseFee:     header.BaseFee,
			}

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
			evm := zvm.New(gethHeader, evmConfig, blockState, getHash)

			// Inject Delta Precompile (Aquarius Feature)
			precompiles := zvm.ActivePrecompiledContracts()
			precompiles[DeltaPrecompileAddress] = &DeltaPrecompile{}
			evm.SetPrecompiles(precompiles)

			gp := new(ethcore.GasPool)
			gp.AddGas(header.GasLimit)

			res, err := ApplyMessage(evm, msg, gp)
			if err != nil {
				fatalErr = err
				break
			}

			// Finalize normally
			e.ProcessSystemContracts(blockState, msg, tx, header)

			gasPrice := tx.GasPrice()
			if header.BaseFee != nil {
				priority := new(big.Int).Add(header.BaseFee, tx.GasTipCap())
				if priority.Cmp(gasPrice) < 0 {
					gasPrice = priority
				}
			}
			fee := new(big.Int).Mul(new(big.Int).SetUint64(res.UsedGas), gasPrice)

			receipt := &ztypes.Receipt{
				TxHash:  tx.Hash(),
				GasUsed: res.UsedGas,
				Logs:    blockState.GetLogs(tx.Hash()),
				Status:  status(res.Failed()),
			}
			if msg.To == nil {
				receipt.ContractAddress = crypto.CreateAddress(msg.From, tx.Nonce())
			}

			blockGasUsed += res.UsedGas
			totalFees.Add(totalFees, fee)

			receipt.CumulativeGasUsed = blockGasUsed
			idx := txIndex[tx.Hash()]
			receipts[idx] = receipt

			continue
		}

		// results buffer for this wave
		waveResults := make([]WaveResult, len(wave))

		waveWg.Add(len(wave))

		for i, tx := range wave {
			go func(i int, tx *types.Transaction) {
				defer waveWg.Done()

				// If already failed (in previous wave), skip
				if fatalErr != nil {
					return
				}

				// Enforce Tx Size Limit (Zephyria PoC: 512KB)
				if tx.Size() > 512*1024 {
					return
				}

				// Create isolated overlay state
				// Note: accessing blockState concurrently to Create Overlay is safe via RLock in NewOverlay
				overlayDB := blockState.NewOverlay()

				// Prepare EVM
				rules := evmConfig.Rules(header.Number, true, header.Time)
				msg, err := ethcore.TransactionToMessage(tx, types.LatestSigner(e.config), header.BaseFee)
				if err != nil {
					waveResults[i].Err = err
					return
				}

				overlayDB.Prepare(rules, msg.From, header.Coinbase, msg.To, vm.ActivePrecompiles(rules), msg.AccessList)

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

				// Aquarius Auto-Binding: Redirect to Data Shard if targeting a Program
				// EXCEPTION: Native Token Program manages its own sharding via SSTORE/SLOAD interception.
				// We do NOT want to lock execution to just the Sender's Shard.
				if msg.To != nil {
					// DEBUG EXECUTOR BATCH
					fmt.Printf("DEBUG: Exec Batch Tx To: %s | TokenProgramID: %s | Equal: %v\n", msg.To.Hex(), state.TokenProgramID.Hex(), *msg.To == state.TokenProgramID)
				}
				if msg.To != nil && *msg.To != state.TokenProgramID {
					// Check if target is a Mint (owned by TokenProgram)
					if owner := overlayDB.GetProgramAddress(*msg.To); owner != state.TokenProgramID {
						// Use the OverlayDB to safely create/bind the data account in this isolated context
						dataCtx, _, redirected := overlayDB.ResolveExecutionTarget(msg.From, *msg.To)
						if redirected {
							fmt.Printf("DEBUG: Redirecting Batch %s -> %s\n", msg.To.Hex(), dataCtx.Hex())
							msg.To = &dataCtx
						}
					}
				}

				stakingAddr := e.netCfg.Params.StakingAddr
				rewardAddr := e.netCfg.Params.RewardAddr
				validatorAddr := e.netCfg.Params.ValidatorAddr
				isSystemTx := msg.To != nil && (*msg.To == stakingAddr || *msg.To == rewardAddr || *msg.To == validatorAddr)
				_ = isSystemTx // Kept for potential future use or logging, but not used for gas refund anymore.

				gethHeader := &types.Header{
					ParentHash:  header.ParentHash,
					UncleHash:   types.EmptyUncleHash,
					Coinbase:    header.Coinbase,
					Root:        header.VerkleRoot,
					TxHash:      types.EmptyRootHash,
					ReceiptHash: types.EmptyRootHash,
					Bloom:       types.Bloom{},
					Difficulty:  big.NewInt(0),
					Number:      header.Number,
					GasLimit:    header.GasLimit,
					GasUsed:     header.GasUsed,
					Time:        header.Time,
					Extra:       header.ExtraData,
					MixDigest:   common.Hash{},
					Nonce:       types.BlockNonce{},
					BaseFee:     header.BaseFee,
				}

				evm := zvm.New(gethHeader, evmConfig, overlayDB, getHash)
				// Inject Delta Precompile
				precompiles := zvm.ActivePrecompiledContracts()
				precompiles[DeltaPrecompileAddress] = &DeltaPrecompile{}
				evm.SetPrecompiles(precompiles)

				gp := new(ethcore.GasPool)
				gp.AddGas(header.GasLimit)

				// Execute via Wrapper
				res, err := ApplyMessage(evm, msg, gp)
				if err != nil {
					fmt.Printf(" [!] FATAL Transaction Error: %s -> %v\n", tx.Hash().Hex()[:10], err)
					waveResults[i].Err = err
					return
				}

				if res.Failed() {
					fmt.Printf(" [!] Tx %s failed (EVM): %v\n", tx.Hash().Hex()[:10], res.Err)
				}

				// If system tx, refund gas and skip fee deduction in final merge
				// Gap 7.1: CHARGE GAS. Do not check isSystemTx to zero it out.
				// We still use isSystemTx for logging or other logic if needed, but we charge gas.
				// if isSystemTx {
				// 	res.UsedGas = 0
				// }

				// Process System Contracts on Overlay
				e.ProcessSystemContracts(overlayDB, msg, tx, header)

				// Calculate Fee
				gasPrice := tx.GasPrice()
				if header.BaseFee != nil {
					priority := new(big.Int).Add(header.BaseFee, tx.GasTipCap())
					if priority.Cmp(gasPrice) < 0 {
						gasPrice = priority
					}
				}
				fee := new(big.Int).Mul(new(big.Int).SetUint64(res.UsedGas), gasPrice)

				// Create Receipt
				receipt := &ztypes.Receipt{
					TxHash:  tx.Hash(),
					GasUsed: res.UsedGas,
					// CumulativeGasUsed: Computed later
					Logs:   overlayDB.GetLogs(tx.Hash()),
					Status: status(res.Failed()),
				}
				if msg.To == nil {
					receipt.ContractAddress = crypto.CreateAddress(msg.From, tx.Nonce())
				}

				// Store Result
				waveResults[i] = WaveResult{
					Overlay: overlayDB,
					GasUsed: res.UsedGas,
					Receipt: receipt,
					Fee:     fee,
					Tx:      tx,
				}
			}(i, tx)
		}
		waveWg.Wait()

		// --- DETEMINISTIC MERGE PHASE ---
		for _, res := range waveResults {
			if res.Err != nil {
				// Fatal error in one of the txs?
				// Just capture first one and break
				if fatalErr == nil {
					fatalErr = res.Err
				}
				continue
			}
			if res.Overlay == nil {
				continue // skipped tx
			}

			// 1. Merge State to Block Context
			res.Overlay.Merge()

			// 2. Update Stats
			blockGasUsed += res.GasUsed
			totalFees.Add(totalFees, res.Fee)

			// 3. Store Receipt
			res.Receipt.CumulativeGasUsed = blockGasUsed
			idx := txIndex[res.Tx.Hash()]
			receipts[idx] = res.Receipt
		}

		// If a fatal error occurred in this wave, stop processing further waves
		if fatalErr != nil {
			return nil, common.Hash{}, fatalErr
		}
	}

	// -------------------------------------------------------------
	// ECONOMICS & FINALIZATION
	// -------------------------------------------------------------
	// 1. Block Reward: Fixed 10 ZEE
	// 2. Tx Fees: Sum of (GasUsed * EffectiveGasPrice)

	reward := new(big.Int).SetUint64(10_000_000_000_000_000_000) // 10 ZEE

	// Add accumulated fees (tracked in totalFees during execution)
	reward.Add(reward, totalFees)

	// Process Unstake Refunds
	e.ProcessMatureUnstakes(blockState, header)

	// Process Epoch on Block State
	e.ProcessEpochBoundary(blockState, header)

	// 3. Distribute Block Reward & Fees
	e.DistributeRewards(blockState, header, reward)

	// Compact Receipts (remove nils from skipped txs)

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

	// SUCCESS: Merge atomic block state to main state
	blockState.Merge()

	root := statedb.IntermediateRoot(false)
	fmt.Printf(" [✓] EXECUTOR: Block #%d Processed. State Root: %s | Txs: %d\n", header.Number.Uint64(), root.Hex()[:10], len(txs))

	// In Verkle, we return the new Root.
	return finalReceipts, root, nil
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

	// FORCE PRODUCTION CONFIG
	evmConfig := getProductionConfig(e.config.ChainID)

	// Prepare EVM
	rules := evmConfig.Rules(header.Number, true, header.Time)

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
		Difficulty:  big.NewInt(0),
		Number:      header.Number,
		GasLimit:    header.GasLimit,
		GasUsed:     header.GasUsed,
		Time:        header.Time,
		Extra:       header.ExtraData,
		MixDigest:   common.Hash{},
		Nonce:       types.BlockNonce{},
		BaseFee:     header.BaseFee,
	}

	evm := zvm.New(gethHeader, evmConfig, overlayDB, getHash)
	precompiles := zvm.ActivePrecompiledContracts()
	precompiles[DeltaPrecompileAddress] = &DeltaPrecompile{}
	evm.SetPrecompiles(precompiles)

	gp := new(ethcore.GasPool)
	gp.AddGas(header.GasLimit)

	// Execute
	return ApplyMessage(evm, msg, gp)
}

// ApplyMessage computes the new state by applying the given message against the old state within the environment.
// It returns the execution result.
func ApplyMessage(evm *zvm.EVM, msg *ethcore.Message, gp *ethcore.GasPool) (*ethcore.ExecutionResult, error) {
	var (
		ret   []byte
		vmerr error // VM execution error
		start = uint64(msg.GasLimit)
	)
	if err := gp.SubGas(msg.GasLimit); err != nil {
		return nil, err
	}
	// Return the remaining gas to the pool
	defer func() {
		gp.AddGas(start - msg.GasLimit)
		if r := recover(); r != nil {
			fmt.Printf(" [!] CRITICAL EVM PANIC: %v\n", r)
			vmerr = fmt.Errorf("EVM Panic: %v", r)
		}
	}()

	var (
		leftOverGas uint64
		address     common.Address
		sender      = msg.From
	)

	// 1. Calculate Intrinsic Gas
	intrinsicGas := uint64(21000)
	if msg.To == nil {
		intrinsicGas += 32000 // Contract creation
	}
	// Data gas: 16 per non-zero, 4 per zero
	for _, b := range msg.Data {
		if b == 0 {
			intrinsicGas += 4
		} else {
			intrinsicGas += 16
		}
	}
	// Access List gas (EIP-2929)
	for _, item := range msg.AccessList {
		intrinsicGas += 2400                                 // Address
		intrinsicGas += uint64(len(item.StorageKeys)) * 1900 // Keys
	}

	if msg.GasLimit < intrinsicGas {
		return nil, fmt.Errorf("intrinsic gas too low: have %d, want %d", msg.GasLimit, intrinsicGas)
	}

	// 2. Adjust gas for EVM execution
	remainingGas := msg.GasLimit - intrinsicGas

	if msg.To == nil {
		ret, address, leftOverGas, vmerr = evm.Create(sender, msg.Data, remainingGas, uint256.MustFromBig(msg.Value))
		_ = address // unused here in result
	} else {
		// Increment nonce for Call/Transfer types (Create handles it internally in local EVM)
		evm.StateDB.SetNonce(sender, evm.StateDB.GetNonce(sender)+1, tracing.NonceChangeEoACall)
		ret, leftOverGas, vmerr = evm.Call(sender, *msg.To, msg.Data, remainingGas, uint256.MustFromBig(msg.Value))
	}

	return &ethcore.ExecutionResult{
		ReturnData: ret,
		UsedGas:    msg.GasLimit - leftOverGas,
		Err:        vmerr,
	}, nil
}

// DistributeRewards distributes block rewards and fees to the validator.
func (e *Executor) DistributeRewards(statedb *state.StateDB, header *ztypes.Header, reward *big.Int) {
	// Simple reward distribution to coinbase for now.
	// In the future, this will split based on commission and delegation.

	// Add balance to coinbase
	statedb.AddBalance(header.Coinbase, uint256.MustFromBig(reward), 0)

	// Update on-chain validator stats
	if e.validatorRegistry != nil {
		info, err := e.validatorRegistry.GetValidatorInfo(statedb, header.Coinbase)
		if err == nil {
			info.TotalRewards = new(big.Int).Add(info.TotalRewards, reward)
			e.validatorRegistry.SetValidatorInfo(statedb, info)
		}
	}
}
