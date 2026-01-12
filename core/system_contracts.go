package core

import (
	"fmt"
	"math/big"
	"strings"

	"zephyria/state"

	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethcore "github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/holiman/uint256"
)

const EpochLength = 100

// ProcessEpochBoundary handles end-of-epoch system logic like Randomness persistence.
func (e *Executor) ProcessEpochBoundary(statedb *state.StateDB, header *ztypes.Header) {
	if header.Number.Uint64()%EpochLength != 0 {
		return
	}

	// ---------------------------------------------------------
	// RANDOMNESS PERSISTENCE
	// ---------------------------------------------------------
	// At epoch boundary, we save the VDF Output (Randomness) to the state.
	// The VDF Output is the first 160 bytes of ExtraData (5 checkpoints * 32 bytes).
	// Or simpler: The "Seed" for next epoch is the LAST VDF Checkpoint of this block.

	// ExtraData Layout: [VDF (160)] [VRF (96)] ...
	// We expect at least 160 bytes.
	if len(header.ExtraData) < 160 {
		return
	}

	// Last Checkpoint (Seed) is bytes [128:160]
	seedBytes := header.ExtraData[128:160]

	randomnessAddr := e.netCfg.Params.RandomnessAddr

	// Key 0: Current Epoch Seed (The one valid for *next* epoch calculation)
	zeroKey := common.Hash{} // Key 0
	val := common.BytesToHash(seedBytes)
	statedb.SetState(randomnessAddr, zeroKey, val)

	// Audit Trail: Key(Epoch) = Seed
	epoch := header.Number.Uint64() / EpochLength
	epochKey := common.BigToHash(new(big.Int).SetUint64(epoch))
	statedb.SetState(randomnessAddr, epochKey, val)

	fmt.Printf("System: Epoch %d Boundary. Randomness Seed Saved: %s\n", epoch, val.Hex())
}

// ProcessSystemContracts checks if a transaction is destined for a system contract and executes native logic.
func (e *Executor) ProcessSystemContracts(overlayDB *state.StateDB, msg *ethcore.Message, tx *types.Transaction, header *ztypes.Header) {
	// ---------------------------------------------------------
	// STAKING CONTRACT LOGIC (Native Go Implementation)
	// ---------------------------------------------------------
	stakingAddr := e.netCfg.Params.StakingAddr
	rewardAddr := e.netCfg.Params.RewardAddr

	sender := msg.From

	if msg.To != nil && *msg.To == stakingAddr {
		// 1. DEPOSIT (Stake)
		if msg.Value.Sign() > 0 {
			// Extract BLS Key from Data (Expected: 48 bytes)
			var blsKey []byte
			if len(msg.Data) == 48 {
				blsKey = msg.Data
			}

			// If already a staker, it's a top-up
			info, _ := e.validatorRegistry.GetValidatorInfo(overlayDB, sender)
			if info != nil {
				if err := e.validatorRegistry.AddStake(overlayDB, sender, msg.Value); err != nil {
					fmt.Printf("System: Validator Stake Top-up Failed: %v\n", err)
				} else {
					fmt.Printf("System: Validator %s Top-up Stake. New Total: %s\n", sender.Hex(), info.Stake.String())
				}
			} else {
				// New Validator Registration
				if len(blsKey) != 48 {
					fmt.Printf("WARNING: Staking tx from %s has no/invalid BLS key! Registration rejected.\n", sender.Hex())
					return
				}
				// Default commission: 10% (1000 basis points)
				if err := e.validatorRegistry.RegisterValidator(overlayDB, sender, msg.Value, blsKey, 1000, header.Number.Uint64()); err != nil {
					fmt.Printf("System: Validator Registration Failed: %v\n", err)
				}
			}
		}

		// 2. WITHDRAW (Unstake)
		if string(tx.Data()) == "UNSTAKE" {
			info, err := e.validatorRegistry.GetValidatorInfo(overlayDB, sender)
			if err != nil {
				fmt.Printf("System: Unstake Attempt by non-validator %s\n", sender.Hex())
				return
			}

			// Request unstake of the ENTIRE amount for simplicity in this implementation
			unlockBlock, err := e.validatorRegistry.RequestUnstake(overlayDB, sender, info.Stake, header.Number.Uint64())
			if err != nil {
				fmt.Printf("System: Unstake Request Failed for %s: %v\n", sender.Hex(), err)
			} else {
				fmt.Printf("System: Unstake Queued for %s. Unlock at %d\n", sender.Hex(), unlockBlock)
			}
		}

		// 3. UPDATE METADATA (METADATA:[Name]:[Website]:[Commission])
		dataStr := string(msg.Data)
		if strings.HasPrefix(dataStr, "METADATA:") {
			parts := strings.Split(dataStr, ":")
			if len(parts) >= 4 {
				name := parts[1]
				website := parts[2]
				commissionVal := uint16(0)
				fmt.Sscanf(parts[3], "%d", &commissionVal)

				if err := e.validatorRegistry.UpdateValidator(overlayDB, sender, name, website, &commissionVal); err != nil {
					fmt.Printf("System: Metadata Update Failed: %v\n", err)
				} else {
					fmt.Printf("System: Validator %s Metadata Updated: %s | %s | %d%%\n",
						sender.Hex(), name, website, commissionVal/100)
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

		// SECURITY FIX: Enforce Coinbase check
		if header != nil && msg.From != header.Coinbase {
			fmt.Printf("SECURITY: Unauthorized Reward Attempt from %s (Expected %s)\n", msg.From.Hex(), header.Coinbase.Hex())
			return
		}

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

	// ---------------------------------------------------------
	// SLASHING CONTRACT LOGIC (Native Go)
	// ---------------------------------------------------------
	if err := e.ProcessSlashing(overlayDB, msg, tx, header); err != nil {
		fmt.Printf("System: Slashing Process Failed: %v\n", err)
	}
}

// ProcessMatureUnstakes checks the queue for unlocked funds and refunds them.
func (e *Executor) ProcessMatureUnstakes(statedb *state.StateDB, header *ztypes.Header) {
	processed := e.validatorRegistry.ProcessMatureUnstakes(statedb, header.Number.Uint64())
	if processed > 0 {
		fmt.Printf("System: Processed %d mature unstake refunds\n", processed)
	}
}

// ProcessSlashing handles a slashing proof transaction.
// It verifies the proof and slashes the validator.
func (e *Executor) ProcessSlashing(overlayDB *state.StateDB, msg *ethcore.Message, tx *types.Transaction, header *ztypes.Header) error {
	// Format: "SLASH:<EvidenceRLP>"
	// For now, we continue with the simplified format "SLASH:<AddressHex>" but use the registry
	data := string(msg.Data)
	if strings.HasPrefix(data, "SLASH:") {
		parts := strings.Split(data, ":")
		if len(parts) == 2 && common.IsHexAddress(parts[1]) {
			targetAddr := common.HexToAddress(parts[1])

			// In a real implementation, we would decode the evidence here.
			// For this PoC, we use empty evidence.
			return e.validatorRegistry.SlashValidator(overlayDB, targetAddr, ztypes.SlashingDoubleSign, nil, header.Number.Uint64(), msg.From)
		}
	} else if strings.HasPrefix(data, "SLASH_PROOF:") {
		// Expecting RLP-encoded SlashingProof after the prefix
		proofData := msg.Data[len("SLASH_PROOF:"):]
		var proof ztypes.SlashingProof
		if err := rlp.DecodeBytes(proofData, &proof); err != nil {
			return fmt.Errorf("failed to decode slashing proof: %v", err)
		}

		// Verify Proof logic (already in engine, but here we are in executor)
		// We can call engine.HandleSlashingProof if we have access, or just registry logic
		return e.validatorRegistry.SlashValidator(
			overlayDB,
			proof.ValidatorAddr,
			proof.ProofType,
			proof.Evidence,
			header.Number.Uint64(),
			msg.From,
		)
	}
	return nil
}
