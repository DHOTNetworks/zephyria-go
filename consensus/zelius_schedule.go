package consensus

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// RecalculateSchedule invalidates the cache.
// In a real system, this would only apply to FUTURE epochs.
func (e *ZeliusEngine) RecalculateSchedule() {
	// For PoC, just clearing cache so GetLeader recalculates
	e.LeaderSchedule = make(map[uint64]common.Address)
}

// GetLeader returns the leader for a given view/block number based on stake weights.
// It mixes the parentHash into the randomness to prevent predictability ("Lookback=1").
func (e *ZeliusEngine) GetLeader(view uint64, parentHash common.Hash) common.Address {
	epoch := view / e.EpochLength
	if epoch > e.CurrentEpoch {
		// New Epoch reached: finalize the validator set for this epoch
		e.CurrentEpoch = epoch
		e.ActiveValidators = make([]*Validator, len(e.Validators))
		copy(e.ActiveValidators, e.Validators)
		// Clear schedule cache for new epoch
		e.LeaderSchedule = make(map[uint64]common.Address)
		e.RecalculateFullPK()
		fmt.Printf(">>> CONSENSUS: Epoch %d Started | Active Validators: %d <<<\n", e.CurrentEpoch, len(e.ActiveValidators))
	}

	// For simple caching, we ignore parentHash collision in cache for now
	// (Assuming linear chain for PoC). In prod, cache key should include hash.
	if leader, ok := e.LeaderSchedule[view]; ok {
		return leader
	}

	// Calculate Leader Deterministically based on Stake from ActiveValidators
	totalStake := new(big.Int)
	for _, v := range e.ActiveValidators {
		totalStake.Add(totalStake, v.Stake)
	}

	// Optimization: If only one validator, they are always the leader.
	if len(e.ActiveValidators) == 1 {
		leader := e.ActiveValidators[0].Address
		e.LeaderSchedule[view] = leader
		return leader
	}

	if totalStake.Sign() == 0 {
		return e.ActiveValidators[view%uint64(len(e.ActiveValidators))].Address
	}

	// Derived Randomness: Hash(EpochSeed || View || ParentHash)
	// This ensures the schedule is unpredictable until the EpochSeed is known (start of epoch).
	seedInput := append(e.CurrentEpochSeed.Bytes(), new(big.Int).SetUint64(view).Bytes()...)
	seedInput = append(seedInput, parentHash.Bytes()...) // Mix Parent Hash (Fix 2.2)

	seed := crypto.Keccak256Hash(seedInput)
	hashVal := new(big.Int).SetBytes(seed.Bytes())
	target := new(big.Int).Mod(hashVal, totalStake)

	current := new(big.Int)
	for _, v := range e.ActiveValidators {
		current.Add(current, v.Stake)
		if current.Cmp(target) >= 0 {
			e.LeaderSchedule[view] = v.Address
			return v.Address
		}
	}
	// Fallback
	leader := e.ActiveValidators[0].Address
	e.LeaderSchedule[view] = leader
	return leader
}

// SelectProposer maps to GetLeader for Zelius.
// It keeps the signature expected by Node but ignores 'seed' argument in favor of deterministic view-based generic schedule.
// Or we can use 'seed' if we want per-round rotation within a view (if HBBFT logic persisted).
// For Zelius (Solana style), the 'slot' (round/view) determines the leader.
func (e *ZeliusEngine) SelectProposer(seed common.Hash, round int) common.Address {
	// We assume 'round' passed from node is effectively the View or Slot index offset?
	// Actually node passes header.Number roughly.
	// Wait, node.go calls: proposer := n.engine.SelectProposer(parent.Hash(), round)
	// round is 0 usually, unless timeout.

	// We can't easily get the absolute block number here without passing it.
	// The interface in node.go uses (seed, round).
	// Let's rely on the fact that existing logic used 'seed' which was parent hash.
	// But 'GetLeader' needs stable index.

	// WE WILL CHANGE SIGNATURE in node.go later.
	// For now, let's implement a wrapper.
	// But to be consistent with 'GetLeader(view)', we need 'view'.
	// Let's assume for this transition that we will fix logic in Node.

	// Existing node.go logic:
	// proposer := n.engine.SelectProposer(parent.Hash(), round)

	// We'll keep this method behaving "roughly" consistent for now but we prefer 'GetLeader'.
	// Actually, let's just use the seed to pick a random one if we lack context,
	// BUT we want Zelius to be deterministic by block number.
	// The current interface doesn't pass block number. We MUST update node.go to call GetLeader(number).

	// IMPLEMENTATION:
	// This function is deprecated in Zelius philosophy but kept for compilation until node.go is updated.
	// We returns a random valid validator to satisfy interface.
	return e.GetLeader(0, seed) // Use seed as parentHash proxy
}
