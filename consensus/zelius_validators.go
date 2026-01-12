package consensus

import (
	"fmt"
	"math/big"
	"zephyria/types"

	bls12381 "github.com/consensys/gnark-crypto/ecc/bls12-381"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
)

// RecalculateFullPK updates the cached aggregate PK of all active validators.
func (e *ZeliusEngine) RecalculateFullPK() {
	if len(e.ActiveValidators) == 0 {
		return
	}
	var agg bls12381.G1Jac
	for _, v := range e.ActiveValidators {
		if len(v.BLSPubKey) > 0 {
			var pk bls12381.G1Affine
			if _, err := pk.SetBytes(v.BLSPubKey); err == nil {
				var pkJac bls12381.G1Jac
				pkJac.FromAffine(&pk)
				agg.AddAssign(&pkJac)
			}
		}
	}
	e.fullSetPK.FromJacobian(&agg)
}

// AddValidator adds a new validator or updates stake.
func (e *ZeliusEngine) AddValidator(addr common.Address, stake *big.Int, blsPubKey []byte) {
	for _, v := range e.Validators {
		if v.Address == addr {
			v.Stake.Add(v.Stake, stake)
			if len(blsPubKey) > 0 {
				v.BLSPubKey = blsPubKey
			}
			e.RecalculateSchedule() // Stake changed, schedule might change next epoch
			return
		}
	}

	v := &Validator{Address: addr, Stake: stake, BLSPubKey: blsPubKey}
	// If no BLS key provided (e.g. legacy add), we would ideally skip or error.
	// For PoC/Dev, we'll log it.
	if len(blsPubKey) == 0 {
		fmt.Printf("WARNING: Validator %s added without BLS Public Key\n", addr.Hex())
	}

	e.Validators = append(e.Validators, v)
	e.f = (len(e.Validators) - 1) / 3
	e.RecalculateSchedule()
}

// RemoveValidator removes a validator.
func (e *ZeliusEngine) RemoveValidator(addr common.Address) {
	if len(e.Validators) <= 1 {
		fmt.Printf("SECURITY ALERT: Cannot remove last validator %s! Network stability at risk.\n", addr.Hex())
		return
	}

	for i, v := range e.Validators {
		if v.Address == addr {
			e.Validators = append(e.Validators[:i], e.Validators[i+1:]...)
			e.f = (len(e.Validators) - 1) / 3
			e.RecalculateSchedule()
			return
		}
	}
}

func (e *ZeliusEngine) Slash(addr common.Address) {
	fmt.Printf("SLASHING VALIDATOR (Zelius): %s\n", addr.Hex())
	// In memory removal (immediate protection)
	e.RemoveValidator(addr)

	// TODO: Broadcast Slashing Transaction?
	// Since we don't have reference to node/txpool here easily (cyclic dependency),
	// we rely on the node loop to detect "Double Sign" or "Compliance Failure" and generate the Tx.
	// ZeliusEngine just updates local view.
}

// RecordNonCompliance records that a validator failed to produce a block in time.
func (e *ZeliusEngine) RecordNonCompliance(addr common.Address) {
	e.NonCompliantValidators[addr]++
	fmt.Printf("NON-COMPLIANCE RECORDED: %s (count: %d)\n", addr.Hex(), e.NonCompliantValidators[addr])

	if e.NonCompliantValidators[addr] >= 20 {
		// Optimization: Don't slash the last validator if we are solo
		if len(e.Validators) <= 1 {
			fmt.Printf("SECURITY ALERT: Not slashing solo validator %s to maintain network liveness.\n", addr.Hex())
			e.NonCompliantValidators[addr] = 0 // Reset
			return
		}

		fmt.Printf("VALIDATOR %s EXCEEDED NON-COMPLIANCE LIMIT (20). SLASHING (Local).\n", addr.Hex())
		e.Slash(addr)
	}
}

// SyncValidators reloads the validator set from the state.
func (e *ZeliusEngine) SyncValidators(stateDB interface{}) error {
	type StateReader interface {
		GetState(common.Address, common.Hash) common.Hash
	}

	s, ok := stateDB.(StateReader)
	if !ok {
		return fmt.Errorf("invalid stateDB type")
	}

	stakingAddr := common.HexToAddress("0x0000000000000000000000000000000000001000")
	validatorAddr := common.HexToAddress("0x0000000000000000000000000000000000003000")

	// 1. Get Count
	countKey := common.Hash{} // Slot 0
	countVal := s.GetState(validatorAddr, countKey)
	count := countVal.Big().Uint64()

	if count == 0 {
		return nil
	}

	var newValidators []*Validator

	for i := uint64(1); i <= count; i++ {
		// Get Address
		indexKey := common.BigToHash(new(big.Int).SetUint64(i))
		addrHash := s.GetState(validatorAddr, indexKey)
		if addrHash == (common.Hash{}) {
			continue
		}
		addr := common.BytesToAddress(addrHash.Bytes())

		// Read ValidatorInfo from chunked RLP
		infoKey := crypto.Keccak256Hash(addr.Bytes(), []byte("INFO"))
		dataKey := crypto.Keccak256Hash(infoKey.Bytes(), []byte("DATA"))

		var rlpData []byte
		for j := uint64(0); j < 10; j++ { // Read up to 10 chunks (320 bytes)
			chunkKey := crypto.Keccak256Hash(dataKey.Bytes(), common.BigToHash(new(big.Int).SetUint64(j)).Bytes())
			chunk := s.GetState(stakingAddr, chunkKey)
			if chunk == (common.Hash{}) {
				break
			}
			rlpData = append(rlpData, chunk.Bytes()...)
		}

		if len(rlpData) == 0 {
			continue
		}

		var info types.ValidatorInfo
		if err := rlp.DecodeBytes(rlpData, &info); err != nil {
			continue
		}

		// Only include active validators in the consensus set
		if info.Status == types.ValidatorActive {
			newValidators = append(newValidators, &Validator{
				Address:   addr,
				Stake:     info.Stake,
				BLSPubKey: info.BLSPubKey,
			})
		}
	}

	// 3. Update Engine
	e.Validators = newValidators
	e.f = (len(e.Validators) - 1) / 3

	// Refresh active list based on liveness if needed, but SyncValidators is the source of truth
	e.ActiveValidators = newValidators

	e.RecalculateSchedule()
	e.RecalculateFullPK()

	// 4. Update Randomness (Epoch Seed)
	randomnessAddr := common.HexToAddress("0x0000000000000000000000000000000000004000")
	seedVal := s.GetState(randomnessAddr, common.Hash{})
	e.CurrentEpochSeed = seedVal

	return nil
}
