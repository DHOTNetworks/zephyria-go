package core

import (
	"fmt"
	"math/big"
	"strings"
	"sync"
	"zephyria/state"
	ztypes "zephyria/types" // Zephyria types

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
}

var (
	StakingAddr = common.HexToAddress("0x0000000000000000000000000000000000001000") // Fallback
	RewardAddr  = common.HexToAddress("0x0000000000000000000000000000000000002000") // Fallback
)

// NewExecutor creates a new Executor.
func NewExecutor(config *params.ChainConfig, netCfg *NetworkConfig) *Executor {
	return &Executor{config: config, netCfg: netCfg}
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

				// Enforce Tx Size Limit (Solana-style: 1232 bytes)
				if tx.Size() > 1232 {
					// Skip oversized tx
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

				overlayDB.Prepare(rules, msg.From, header.Coinbase, nil, vm.ActivePrecompiles(rules), nil)

				evm := vm.NewEVM(vm.BlockContext{
					CanTransfer: ethcore.CanTransfer,
					Transfer:    ethcore.Transfer,
					GetHash:     func(n uint64) common.Hash { return common.Hash{} },
					Coinbase:    header.Coinbase,
					BlockNumber: header.Number,
					Time:        header.Time,
					Difficulty:  header.Difficulty,
					GasLimit:    header.GasLimit,
					BaseFee:     header.BaseFee,
				}, overlayDB, e.config, vm.Config{})

				gp := new(ethcore.GasPool)
				gp.AddGas(header.GasLimit) // Allocation per tx? or shared? In parallel, shared is tricky.
				// Give full limit to each, but cap at block end?
				// For Sealevel, each tx has a limit.

				// Execute
				// Zephyria: Fee-free system contracts
				stakingAddr := e.netCfg.Params.StakingAddr
				rewardAddr := e.netCfg.Params.RewardAddr
				validatorAddr := e.netCfg.Params.ValidatorAddr
				isSystemTx := msg.To != nil && (*msg.To == stakingAddr || *msg.To == rewardAddr || *msg.To == validatorAddr)

				res, err := ethcore.ApplyMessage(evm, msg, gp)
				if err != nil {
					return
				}

				// If system tx, refund gas and skip fee deduction in final merge
				if isSystemTx {
					res.UsedGas = 0
				}

				// ---------------------------------------------------------
				// STAKING CONTRACT LOGIC (Native Go Implementation)
				// ---------------------------------------------------------
				sender := msg.From

				if msg.To != nil && *msg.To == stakingAddr {
					// 1. DEPOSIT (Stake)
					if msg.Value.Sign() > 0 {
						// Store Stake: State[StakingAddr][SenderHash] = Value
						// For PoC: We overwrite (assuming single stake tx per user)
						// In prod: Read + Add.

						// Convert Value to Hash (Storage format)
						// Note: Value is uint256.Int. usage depends on geth version in use by Executor wrapper.
						// msg.Value is likely *big.Int or *uint256.Int depending on TransactionToMessage.
						// ethcore.TransactionToMessage returns core.Message which uses *big.Int usually.
						valBytes := common.BigToHash(msg.Value)
						key := common.BytesToHash(sender.Bytes()) // Simple key
						overlayDB.SetState(stakingAddr, key, valBytes)

						// Update ValidatorSet (0x3000): Mark sender as Active
						overlayDB.SetState(validatorAddr, key, common.HexToHash("0x1"))
						// fmt.Printf("State: Staked %s for %s\n", msg.Value, sender.Hex())
					}

					// 2. WITHDRAW (Unstake)
					if string(tx.Data()) == "UNSTAKE" {
						key := common.BytesToHash(sender.Bytes())
						storedVal := overlayDB.GetState(stakingAddr, key)

						if (storedVal != common.Hash{}) {
							amount := storedVal.Big()

							// Minimum Unstake Check (PoC: 1 ZEE)
							// if amount.Cmp(big.NewInt(1000000000000000000)) < 0 { return }

							// Refund: StakingAddr -> Sender
							// Need uint256 for AddBalanceReward (which acts as AddBalance generic)
							amt256, _ := uint256.FromBig(amount)

							// Security: Ensure StakingAddr has enough balance (it should if state is consistent)
							if overlayDB.GetBalance(stakingAddr).Cmp(amt256) >= 0 {
								overlayDB.SubBalance(stakingAddr, amt256, tracing.BalanceChangeReason(0))
								overlayDB.AddBalance(sender, amt256, tracing.BalanceChangeReason(0))

								// Zero out storage in both contracts
								overlayDB.SetState(stakingAddr, key, common.Hash{})
								overlayDB.SetState(validatorAddr, key, common.Hash{})
							}
						}
					}
				}

				// ---------------------------------------------------------
				// GENESIS REWARD CONTRACT LOGIC (Native Go)
				// ---------------------------------------------------------
				if msg.To != nil && *msg.To == rewardAddr {
					// Logic: RewardAddr acts as a central vault.
					// Only the Coinbase (Miner) can trigger a withdrawal from it.
					// This prevents unauthorized draining of the reward pool.
					if sender == header.Coinbase && msg.Value.Sign() == 0 && len(tx.Data()) > 0 {
						// Format: "REWARD:<addr>:<amount_hex>"
						data := string(tx.Data())
						if len(data) > 7 && data[:7] == "REWARD:" {
							parts := strings.Split(data[7:], ":")
							if len(parts) == 2 {
								targetAddr := common.HexToAddress(parts[0])
								rewardAmt, _ := new(big.Int).SetString(parts[1], 16)

								if rewardAmt != nil {
									amt256, _ := uint256.FromBig(rewardAmt)
									// Check pool balance
									poolBal := overlayDB.GetBalance(rewardAddr)
									if poolBal.Cmp(amt256) >= 0 {
										overlayDB.SubBalance(rewardAddr, amt256, tracing.BalanceChangeReason(0))
										overlayDB.AddBalance(targetAddr, amt256, tracing.BalanceChangeReason(0))
										fmt.Printf("Genesis Reward: Distributed %s to %s\n", rewardAmt, targetAddr.Hex())
									}
								}
							}
						}
					}
				}

				// ---------------------------------------------------------
				// VALIDATOR SET CONTRACT LOGIC (Native Go)
				// ---------------------------------------------------------
				if msg.To != nil && *msg.To == validatorAddr {
					// Handle validator activation/deactivation logic
					// This would be triggered by StakingAddr or specialized protocol txs
				}
				mergeLock.Lock()
				overlayDB.Merge()
				blockGasUsed += res.UsedGas // Track total gas

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
	// 2. Tx Fees: Total Gas Used * Base Fee
	// (Note: In EIP-1559, BaseFee is burned. Tip is given to miner.
	// For Zephyria PoC, we give full fees to miner for simplicity/incentive).

	reward := new(big.Int).SetUint64(10_000_000_000_000_000_000) // 10 ZEE
	if header.BaseFee != nil {
		fees := new(big.Int).Mul(new(big.Int).SetUint64(blockGasUsed), header.BaseFee)
		reward.Add(reward, fees)
	}

	statedb.AddBalanceReward(header.Coinbase, uint256.MustFromBig(reward))
	// fmt.Printf("Miner %s rewarded %s zei (Gas: %d)\n", header.Coinbase.Hex(), reward, blockGasUsed)

	// Compact Receipts (remove nils from skipped txs)
	finalReceipts := make([]*ztypes.Receipt, 0)
	cumulative := uint64(0)
	for _, r := range receipts {
		if r != nil {
			cumulative += r.GasUsed
			r.CumulativeGasUsed = cumulative // Correct cumulative calculation sequentially
			finalReceipts = append(finalReceipts, r)
		}
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

// schedule groups transactions into "waves". Transactions in the same wave are independent.
func (e *Executor) schedule(txs []*types.Transaction) [][]*types.Transaction {
	var waves [][]*types.Transaction

	// Pending transactions that haven't been scheduled
	queue := make([]*types.Transaction, len(txs))
	copy(queue, txs)

	signer := types.LatestSigner(e.config)

	for len(queue) > 0 {
		var currentWave []*types.Transaction
		var nextQueue []*types.Transaction

		touched := make(map[common.Address]bool)

		for _, tx := range queue {
			sender, _ := types.Sender(signer, tx) // Cached
			recipient := common.Address{}
			if tx.To() != nil {
				recipient = *tx.To()
			}

			// Check conflicts
			if touched[sender] || (tx.To() != nil && touched[recipient]) {
				// Conflict: defer to next wave
				nextQueue = append(nextQueue, tx)
			} else {
				// Independent: add to wave
				currentWave = append(currentWave, tx)
				touched[sender] = true
				if tx.To() != nil {
					touched[recipient] = true
				}
			}
		}

		if len(currentWave) == 0 {
			// Should not happen unless cyclic dependency in single tx? (Impossible self-conflict logic above)
			// Or just safer to break to avoid infinite loop
			if len(nextQueue) > 0 {
				// Force one to progress
				waves = append(waves, []*types.Transaction{nextQueue[0]})
				queue = nextQueue[1:]
			} else {
				break
			}
		} else {
			waves = append(waves, currentWave)
			queue = nextQueue
		}
	}

	return waves
}
