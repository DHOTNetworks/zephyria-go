package consensus

import (
	"math/big"
	"sync"

	"zephyria/types"

	bls12381 "github.com/consensys/gnark-crypto/ecc/bls12-381"
	"github.com/ethereum/go-ethereum/common"
)

// VotePool manages receiving and aggregating votes.
type VotePool struct {
	mu     sync.Mutex
	votes  map[common.Hash]map[uint64]*types.Vote // BlockHash -> ValIndex -> Vote
	engine *ZeliusEngine
}

func NewVotePool(engine *ZeliusEngine) *VotePool {
	return &VotePool{
		votes:  make(map[common.Hash]map[uint64]*types.Vote),
		engine: engine,
	}
}

// AddVote adds a vote to the pool and returns true if it's new and valid.
// In a real implementation, we would verify the signature here immediately.
// For performance, we might batch verify or verify before adding.
func (vp *VotePool) AddVote(vote *types.Vote) bool {
	vp.mu.Lock()
	defer vp.mu.Unlock()

	if _, ok := vp.votes[vote.BlockHash]; !ok {
		vp.votes[vote.BlockHash] = make(map[uint64]*types.Vote)
	}

	if _, exists := vp.votes[vote.BlockHash][vote.ValidatorIndex]; exists {
		return false // Duplicate
	}

	// Basic Validation: Index out of bounds?
	// We need access to the validator set for that block epoch.
	// For simplicity, we check against current ActiveValidators.
	if vote.ValidatorIndex >= uint64(len(vp.engine.ActiveValidators)) {
		return false
	}

	// Verify Signature
	if !vp.engine.VerifyVoteSignature(vote.ValidatorIndex, vote.BlockHash, vote.View, vote.Signature) {
		return false
	}

	vp.votes[vote.BlockHash][vote.ValidatorIndex] = vote
	return true
}

// Prune removes votes for views older than minView.
func (vp *VotePool) Prune(minView uint64) {
	vp.mu.Lock()
	defer vp.mu.Unlock()

	for hash, votes := range vp.votes {
		// Optimization: Check one vote to see the view (all votes for a block should be same view)
		var view uint64
		for _, v := range votes {
			view = v.View
			break
		}

		if view < minView {
			delete(vp.votes, hash)
		}
	}
}

// CheckQuorum checks if a block has enough votes (>2/3) and returns the aggregated signature (Quorum Certificate).
func (vp *VotePool) CheckQuorum(blockHash common.Hash) (bool, []byte, []byte) {
	vp.mu.Lock()
	defer vp.mu.Unlock()

	votes, ok := vp.votes[blockHash]
	if !ok {
		return false, nil, nil
	}

	totalStake := new(big.Int)
	votedStake := new(big.Int)

	// Calculate Total Stake
	for _, val := range vp.engine.ActiveValidators {
		totalStake.Add(totalStake, val.Stake)
	}

	// Calculate Voted Stake & Aggregate
	var aggSig bls12381.G2Jac
	bitmask := make([]byte, (len(vp.engine.ActiveValidators)+7)/8)

	count := 0
	for idx, vote := range votes {
		if idx >= uint64(len(vp.engine.ActiveValidators)) {
			continue
		}
		val := vp.engine.ActiveValidators[idx]
		votedStake.Add(votedStake, val.Stake)

		// Aggregate Signature
		var sig bls12381.G2Affine
		if _, err := sig.SetBytes(vote.Signature); err == nil {
			var sigJac bls12381.G2Jac
			sigJac.FromAffine(&sig)
			aggSig.AddAssign(&sigJac)
		}

		// Set Bitmask
		byteIdx := idx / 8
		bitIdx := idx % 8
		bitmask[byteIdx] |= (1 << bitIdx)
		count++
	}

	// Check 2/3 Threshold
	// threshold = (2 * total) / 3
	threshold := new(big.Int).Mul(totalStake, big.NewInt(2))
	threshold.Div(threshold, big.NewInt(3))

	if votedStake.Cmp(threshold) > 0 {
		var finalSig bls12381.G2Affine
		finalSig.FromJacobian(&aggSig)
		sigBytes := finalSig.Bytes()
		return true, sigBytes[:], bitmask
	}

	return false, nil, nil
}
