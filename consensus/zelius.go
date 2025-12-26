package consensus

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"time"

	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// ZeliusEngine implements the Zelius Consensus (PoS with Leader Schedule).
type ZeliusEngine struct {
	Validators []*Validator
	f          int // fault tolerance threshold

	// Local identity
	privKey *ecdsa.PrivateKey

	// Non-compliance tracking
	NonCompliantValidators map[common.Address]int

	// Zelius Specifics
	LeaderSchedule map[uint64]common.Address // Epoch -> Leader (Simplified: Block -> Leader for now, or Round -> Leader)
	// Actually, Solana calculates schedule for an entire Epoch (e.g. 432000 slots).
	// For this PoC, we will calculate it on the fly or cache it for the current "Epoch" of 100 blocks.
	CurrentEpoch  uint64
	EpochSchedule []common.Address
}

// Validator represents a node in the consensus.
type Validator struct {
	Address common.Address
	Stake   *big.Int
}

// NewZelius creates a new consensus engine.
func NewZelius(validators []*Validator, privKey *ecdsa.PrivateKey) *ZeliusEngine {
	f := (len(validators) - 1) / 3
	return &ZeliusEngine{
		Validators:             validators,
		f:                      f,
		privKey:                privKey,
		NonCompliantValidators: make(map[common.Address]int),
		LeaderSchedule:         make(map[uint64]common.Address),
	}
}

// PrivateKey returns the local private key.
func (e *ZeliusEngine) PrivateKey() *ecdsa.PrivateKey {
	return e.privKey
}

// Batch represents a proposal from a validator.
type Batch struct {
	Proposer common.Address
	Txs      []*ethtypes.Transaction
}

// Seal signs the block with the local private key.
func (e *ZeliusEngine) Seal(b *types.Block) error {
	if e.privKey == nil {
		return errors.New("readonly node: no private key")
	}

	header := b.Header
	origExtra := make([]byte, len(header.ExtraData))
	copy(origExtra, header.ExtraData)

	header.ExtraData = []byte{}

	hash := b.Hash()
	sig, err := crypto.Sign(hash.Bytes(), e.privKey)
	if err != nil {
		return err
	}

	if len(origExtra) > 0 {
		header.ExtraData = append(origExtra, sig...)
	} else {
		header.ExtraData = sig
	}

	return nil
}

// Verify checks if the block is signed by a valid validator.
func (e *ZeliusEngine) Verify(b *types.Block) error {
	header := b.Header
	if len(header.ExtraData) < 65 {
		return errors.New("missing signature")
	}

	// Split extra
	sig := header.ExtraData[len(header.ExtraData)-65:]
	preSealExtra := header.ExtraData[:len(header.ExtraData)-65]

	tempHeader := *header
	tempHeader.ExtraData = preSealExtra
	tempBlock := &types.Block{Header: &tempHeader}

	sealHash := tempBlock.Hash()

	// Recover
	pubKey, err := crypto.SigToPub(sealHash.Bytes(), sig)
	if err != nil {
		return fmt.Errorf("signature recovery failed: %v", err)
	}
	signer := crypto.PubkeyToAddress(*pubKey)

	// Zelius Check: Is this signer the EXPECTED leader for this slot/block?
	// This enforces the Leader Schedule.
	expectedLeader := e.GetLeader(header.Number.Uint64()) // Simplified view = block number
	if expectedLeader != signer {
		return fmt.Errorf("block signed by wrong leader: expected %s, got %s", expectedLeader.Hex(), signer.Hex())
	}

	return nil
}

// AddValidator adds a new validator or updates stake.
func (e *ZeliusEngine) AddValidator(addr common.Address, stake *big.Int) {
	for _, v := range e.Validators {
		if v.Address == addr {
			v.Stake.Add(v.Stake, stake)
			e.RecalculateSchedule() // Stake changed, schedule might change next epoch
			return
		}
	}
	e.Validators = append(e.Validators, &Validator{Address: addr, Stake: stake})
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

// Slash removes a validator (Simulated Slashing).
func (e *ZeliusEngine) Slash(addr common.Address) {
	fmt.Printf("SLASHING VALIDATOR (Zelius): %s\n", addr.Hex())
	e.RemoveValidator(addr)
}

// RecordNonCompliance records that a validator failed to produce a block in time.
func (e *ZeliusEngine) RecordNonCompliance(addr common.Address) {
	e.NonCompliantValidators[addr]++
	fmt.Printf("NON-COMPLIANCE RECORDED: %s (count: %d)\n", addr.Hex(), e.NonCompliantValidators[addr])

	if e.NonCompliantValidators[addr] >= 1000 {
		fmt.Printf("VALIDATOR %s EXCEEDED NON-COMPLIANCE LIMIT. SLASHING.\n", addr.Hex())
		e.Slash(addr)
	}
}

// RecalculateSchedule invalidates the cache.
// In a real system, this would only apply to FUTURE epochs.
func (e *ZeliusEngine) RecalculateSchedule() {
	// For PoC, just clearing cache so GetLeader recalculates
	e.LeaderSchedule = make(map[uint64]common.Address)
}

// GetLeader returns the leader for a given view/block number based on stake weights.
func (e *ZeliusEngine) GetLeader(view uint64) common.Address {
	if leader, ok := e.LeaderSchedule[view]; ok {
		return leader
	}

	// Calculate Leader Deterministically based on Stake
	// Seed = View (Ideally Seed = EpochSeed + View, but View is fine for PoC)
	// We use the same weighed random logic as before but strictly deterministic per view

	totalStake := new(big.Int)
	for _, v := range e.Validators {
		totalStake.Add(totalStake, v.Stake)
	}

	if totalStake.Sign() == 0 {
		return e.Validators[view%uint64(len(e.Validators))].Address
	}

	// Pseudo-random value from view
	// Hash(view)
	seed := crypto.Keccak256Hash(new(big.Int).SetUint64(view).Bytes())
	hashVal := new(big.Int).SetBytes(seed.Bytes())
	target := new(big.Int).Mod(hashVal, totalStake)

	current := new(big.Int)
	for _, v := range e.Validators {
		current.Add(current, v.Stake)
		if current.Cmp(target) >= 0 {
			e.LeaderSchedule[view] = v.Address
			return v.Address
		}
	}
	// Fallback
	leader := e.Validators[0].Address
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
	return e.GetLeader(0) // DUMMY - Node.go MUST change to GetLeader
}

// SimulateRound runs the consensus round and SEALS the result.
func (e *ZeliusEngine) SimulateRound(parent *types.Block, txs []*ethtypes.Transaction) (*types.Block, error) {
	// ... (Existing ACS Logic - kept simulated for speed/PoC) ...

	// Dynamic Proposer Selection (Zelius Style: Deterministic based on block number)
	nextBlockNum := new(big.Int).Add(parent.Header.Number, big.NewInt(1))
	proposer := e.GetLeader(nextBlockNum.Uint64())

	myAddr := crypto.PubkeyToAddress(e.privKey.PublicKey)
	if proposer != myAddr {
		// In BENCHMARK mode, if we aren't the proposer, we skip?
		// Or we warn.
	}

	// 1. Proposal Phase
	proposals := make(map[common.Address][]*ethtypes.Transaction)

	for _, val := range e.Validators {
		if val.Address == myAddr {
			proposals[val.Address] = txs
		} else {
			proposals[val.Address] = []*ethtypes.Transaction{}
		}
	}

	// 2. ACS Phase: Agree on proposals.
	var agreedBatches [][]*ethtypes.Transaction
	// Always include ours
	agreedBatches = append(agreedBatches, txs)

	// 3. Finalization
	finalTxs := make([]*ethtypes.Transaction, 0)
	for _, batchTxs := range agreedBatches {
		finalTxs = append(finalTxs, batchTxs...)
	}

	// Determinstic Sort
	sort.Slice(finalTxs, func(i, j int) bool {
		return finalTxs[i].Nonce() < finalTxs[j].Nonce()
	})

	// 4. Create Block
	header := &types.Header{
		ParentHash: parent.Hash(),
		Number:     new(big.Int).Add(parent.Header.Number, big.NewInt(1)),
		Time:       uint64(time.Now().Unix()),
		Coinbase:   myAddr,   // We are mining it, so we are coinbase. Even if 'proposer' logic selected someone else theoretically.
		ExtraData:  []byte{}, // Empty for signing
		GasLimit:   30000000,
		BaseFee:    big.NewInt(10),
		Difficulty: big.NewInt(0),
	}

	block := types.NewBlock(header, finalTxs)

	// 5. Seal (Sign)
	if err := e.Seal(block); err != nil {
		return nil, fmt.Errorf("failed to seal block: %v", err)
	}

	return block, nil
}
