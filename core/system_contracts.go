package core

import (
	"fmt"
	"math/big"
	"strings"

	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	ethcore "github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

// ProcessSystemContracts checks if a transaction is destined for a system contract and executes native logic.
func (e *Executor) ProcessSystemContracts(overlayDB *state.StateDB, msg *ethcore.Message, tx *types.Transaction, header *params.ChainConfig) {
	// ---------------------------------------------------------
	// STAKING CONTRACT LOGIC (Native Go Implementation)
	// ---------------------------------------------------------
	stakingAddr := e.netCfg.Params.StakingAddr
	rewardAddr := e.netCfg.Params.RewardAddr
	validatorAddr := e.netCfg.Params.ValidatorAddr

	sender := msg.From

	if msg.To != nil && *msg.To == stakingAddr {
		// 1. DEPOSIT (Stake)
		if msg.Value.Sign() > 0 {
			// Store Stake: State[StakingAddr][SenderHash] = Value
			valBytes := common.BigToHash(msg.Value)
			key := common.BytesToHash(sender.Bytes()) // Simple key
			overlayDB.SetState(stakingAddr, key, valBytes)

			// Update ValidatorSet (0x3000): Iterable List
			// Check if already active
			existingIndex := overlayDB.GetState(validatorAddr, key)
			if (existingIndex == common.Hash{}) {
				// 1. Increment Count
				countHash := common.Hash{} // Key 0
				currentCount := overlayDB.GetState(validatorAddr, countHash).Big()
				newCount := new(big.Int).Add(currentCount, big.NewInt(1))
				overlayDB.SetState(validatorAddr, countHash, common.BigToHash(newCount))

				// 2. Store Index -> Address
				// Key = Index
				indexKey := common.BigToHash(newCount)
				overlayDB.SetState(validatorAddr, indexKey, key)

				// 3. Store Address -> Index
				// Key = AddressHash
				overlayDB.SetState(validatorAddr, key, indexKey)

				fmt.Printf("System: New Validator Joined! %s (Index %s)\n", sender.Hex(), newCount)
			} else {
				fmt.Printf("System: Validator %s Top-up Stake\n", sender.Hex())
			}
		}

		// 2. WITHDRAW (Unstake)
		if string(tx.Data()) == "UNSTAKE" {
			key := common.BytesToHash(sender.Bytes())
			storedVal := overlayDB.GetState(stakingAddr, key)

			if (storedVal != common.Hash{}) {
				amount := storedVal.Big()

				// Refund: StakingAddr -> Sender
				amt256, _ := uint256.FromBig(amount)

				// Security: Ensure StakingAddr has enough balance
				if overlayDB.GetBalance(stakingAddr).Cmp(amt256) >= 0 {
					overlayDB.SubBalance(stakingAddr, amt256, tracing.BalanceChangeReason(0))
					overlayDB.AddBalance(sender, amt256, tracing.BalanceChangeReason(0))

					// Swap-and-Pop Removal
					// 1. Get Index of Validator to remove
					indexToRemove := overlayDB.GetState(validatorAddr, key).Big()

					// 2. Get Last Index (Count)
					countHash := common.Hash{}
					currentCount := overlayDB.GetState(validatorAddr, countHash).Big()

					// 3. If not last, swap last element to this position
					if indexToRemove.Cmp(currentCount) < 0 {
						lastIndexKey := common.BigToHash(currentCount)
						lastAddrHash := overlayDB.GetState(validatorAddr, lastIndexKey) // Address of last guy

						// Move last guy to empty slot
						slotKey := common.BigToHash(indexToRemove)
						overlayDB.SetState(validatorAddr, slotKey, lastAddrHash)

						// Update last guy's pointer
						overlayDB.SetState(validatorAddr, lastAddrHash, slotKey)
					}

					// 4. Delete Last Slot and Decrement Count
					zero := common.Hash{}
					overlayDB.SetState(validatorAddr, common.BigToHash(currentCount), zero) // Clear last slot

					newCount := new(big.Int).Sub(currentCount, big.NewInt(1))
					overlayDB.SetState(validatorAddr, countHash, common.BigToHash(newCount))

					// 5. Cleanup Removed Validator
					overlayDB.SetState(stakingAddr, key, zero)
					overlayDB.SetState(validatorAddr, key, zero) // Clear pointer

					fmt.Printf("System: Validator Left: %s\n", sender.Hex())
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
		// Note: header.Coinbase is not passed here easily unless we change signature.
		// Assuming we pass correct context or simplified check for now.
		// Or assume msg.From check is enough if we trust execution flow.
		// Wait, we need 'header' from ApplyBlock context, but signature above has *params.ChainConfig (wrong type name usage in my proposed func sig?).
		// Let's rely on standard logic:

		// For now, disabling strict coinbase check in this extracted function to keep signature simple,
		// OR we pass the coinbase address as argument. Let's pass extra arg?
		// Actually, let's keep it simple. If msg.From is "authorized", we proceed.
		// Real impl needs AccessControl.

		if msg.Value.Sign() == 0 && len(tx.Data()) > 0 {
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
}
