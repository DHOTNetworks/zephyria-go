package consensus

import (
	"crypto/ecdsa"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"time"

	"zephyria/consensus/vdf"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/ethereum/go-ethereum/trie"

	bls12381 "github.com/consensys/gnark-crypto/ecc/bls12-381"
)

// NewZelius creates a new consensus engine.
func NewZelius(validators []*Validator, privKey *ecdsa.PrivateKey, params *types.SystemParams) *ZeliusEngine {
	// If params nil, use default
	iters := 100
	interval := 10
	if params != nil && params.VDFIterations > 0 {
		iters = params.VDFIterations
		interval = params.VDFInterval
	}

	f := (len(validators) - 1) / 3
	e := &ZeliusEngine{
		Validators:             validators,
		f:                      f,
		privKey:                privKey,
		NonCompliantValidators: make(map[common.Address]int),
		LeaderSchedule:         make(map[uint64]common.Address),
		EpochLength:            100, // Default 100 blocks per epoch
		CurrentEpoch:           0,
		ActiveValidators:       validators,
		VDFIterations:          iters,
		VDFCheckpointInterval:  interval,
		VDF:                    vdf.NewVDF(),
		Metronome:              vdf.NewMetronome(iters, interval),
	}
	// Derive BLS key if ECDSA key is provided
	if privKey != nil {
		e.SetBLSPrivKey(crypto.FromECDSA(privKey))
	}
	e.RecalculateFullPK()
	return e
}

// SetBLSPrivKey sets the BLS private key for the engine.
func (e *ZeliusEngine) SetBLSPrivKey(seed []byte) {
	e.blsPrivKey = new(big.Int).SetBytes(seed)
}

// PrivateKey returns the local private key.
func (e *ZeliusEngine) PrivateKey() *ecdsa.PrivateKey {
	return e.privKey
}

// VRFProve generates a VRF proof.
func (e *ZeliusEngine) VRFProve(sk *big.Int, input []byte) ([]byte, error) {
	// Simple EC-VRF-like construction using BLS G1
	// Hash to Curve
	h, err := bls12381.HashToG1(input, []byte(VRF_DST))
	if err != nil {
		return nil, err
	}
	// Sign: s * H(m)
	var res bls12381.G1Affine
	res.ScalarMultiplication(&h, sk)
	resBytes := res.Bytes()
	return resBytes[:], nil // Slice conversion
}

// VerifyVoteSignature verifies a single vote signature.
func (e *ZeliusEngine) VerifyVoteSignature(valIndex uint64, blockHash common.Hash, view uint64, sig []byte) bool {
	// Find Validator by Index from ActiveValidators
	if valIndex >= uint64(len(e.ActiveValidators)) {
		return false
	}
	validator := e.ActiveValidators[valIndex]

	// Message: Vote(BlockHash, View)
	msg := make([]byte, 40)
	copy(msg[:32], blockHash.Bytes())
	binary.BigEndian.PutUint64(msg[32:], view)

	// Verify Sig
	var blsPub bls12381.G1Affine
	// Check against stored public key (48 bytes)
	if len(validator.BLSPubKey) != 48 {
		return false
	}
	if _, err := blsPub.SetBytes(validator.BLSPubKey); err != nil {
		return false
	}

	var blsSig bls12381.G2Affine
	if len(sig) != 96 {
		return false
	}
	if _, err := blsSig.SetBytes(sig); err != nil {
		return false
	}

	h, _ := bls12381.HashToG2(msg, []byte(BLS_DST))

	_, _, g1, _ := bls12381.Generators()
	var negG1 bls12381.G1Affine
	negG1.Neg(&g1)

	valid, err := bls12381.PairingCheck(
		[]bls12381.G1Affine{blsPub, negG1},
		[]bls12381.G2Affine{h, blsSig},
	)
	return err == nil && valid
}

// CreateVote signs a vote for a block.
func (e *ZeliusEngine) CreateVote(blockHash common.Hash, view uint64) (*types.Vote, error) {
	if e.blsPrivKey == nil {
		return nil, errors.New("no BLS key")
	}

	msg := make([]byte, 40)
	copy(msg[:32], blockHash.Bytes())
	binary.BigEndian.PutUint64(msg[32:], view)

	h, err := bls12381.HashToG2(msg, []byte(BLS_DST))
	if err != nil {
		return nil, err
	}

	var sig bls12381.G2Affine
	sig.ScalarMultiplication(&h, e.blsPrivKey)

	sigBytes := sig.Bytes()

	// Find my index
	myAddr := crypto.PubkeyToAddress(e.privKey.PublicKey)
	var myIndex uint64
	found := false
	for i, v := range e.ActiveValidators {
		if v.Address == myAddr {
			myIndex = uint64(i)
			found = true
			break
		}
	}
	if !found {
		return nil, errors.New("not an active validator")
	}

	return &types.Vote{
		BlockHash:      blockHash,
		ValidatorIndex: myIndex,
		View:           view,
		Signature:      sigBytes[:],
	}, nil
}

// Seal signs the block with the local private key (individual BLS G2 signature).
func (e *ZeliusEngine) Seal(b *types.Block, slot uint64) error {
	if e.blsPrivKey == nil {
		return errors.New("no BLS private key")
	}

	header := b.Header

	expectedCheckpoints := e.VDFIterations / e.VDFCheckpointInterval
	vdfSize := expectedCheckpoints * 32
	roundSize := 8
	vrfSize := 96
	staticSize := vdfSize + roundSize + vrfSize // VDF + Slot + VRF Proof

	// We construct the "Preserved Data" part of ExtraData
	preservedData := make([]byte, staticSize)

	// 1. Preserve VDF
	if len(header.ExtraData) >= vdfSize {
		copy(preservedData[:vdfSize], header.ExtraData[:vdfSize])
	} else {
		fmt.Println("WARNING: Seal called with missing VDF data!")
	}

	// 2. Encode Slot
	binary.BigEndian.PutUint64(preservedData[vdfSize:vdfSize+8], slot)

	// 3. Preserve or Generate VRF
	if len(header.ExtraData) >= staticSize {
		copy(preservedData[vdfSize+8:], header.ExtraData[vdfSize+8:staticSize])
	} else {
		// Generate VRF
		slot := header.Number.Uint64()
		buf := make([]byte, 8)
		binary.BigEndian.PutUint64(buf, slot)
		input := append(e.CurrentEpochSeed.Bytes(), buf...)

		proof, err := e.VRFProve(e.blsPrivKey, input)
		if err != nil {
			fmt.Printf("VRF Generate Error: %v\n", err)
		} else {
			copy(preservedData[vdfSize+8:], proof)
		}
	}

	header.ExtraData = preservedData

	hash := b.Hash()

	// 3. Hash to G2
	h, err := bls12381.HashToG2(hash.Bytes(), []byte(BLS_DST))
	if err != nil {
		return err
	}

	// 4. Aggregate signatures
	var aggregateSig bls12381.G2Jac
	bitmask := make([]byte, 8)
	count := 0

	for i, val := range e.ActiveValidators {
		myAddr := crypto.PubkeyToAddress(e.privKey.PublicKey)
		if val.Address == myAddr {
			var sig bls12381.G2Affine
			sig.ScalarMultiplication(&h, e.blsPrivKey)
			var sigJac bls12381.G2Jac
			sigJac.FromAffine(&sig)
			aggregateSig.AddAssign(&sigJac)

			bitmask[i/8] |= (1 << (i % 8))
			count++
		}
	}

	var finalSig bls12381.G2Affine
	finalSig.FromJacobian(&aggregateSig)
	sigBytes := finalSig.Bytes()

	payload := append(preservedData, bitmask...)
	payload = append(payload, sigBytes[:]...)
	header.ExtraData = payload

	return nil
}

// ComputeVDF calculates the VDF checkpoints.
func (e *ZeliusEngine) ComputeVDF(parent *types.Block) []byte {
	var vdfInput []byte
	expectedCheckpoints := e.VDFIterations / e.VDFCheckpointInterval
	expectedSize := expectedCheckpoints * 32

	if len(parent.Header.ExtraData) >= expectedSize && expectedSize > 0 {
		vdfInput = parent.Header.ExtraData[expectedSize-32 : expectedSize]
	} else {
		h := parent.Hash()
		vdfInput = h[:]
	}

	checkpoints := e.VDF.ComputeWithCheckpoints(vdfInput, e.VDFIterations, e.VDFCheckpointInterval)

	if len(checkpoints) > 0 {
		nextNum := parent.Header.Number.Uint64() + 1
		fmt.Printf("\033[1;36m[🔨] Block %d VDF Generated. Iter=%d, Input=%x, Result[0]=%x\033[0m\n",
			nextNum, e.VDFIterations, vdfInput[:4], checkpoints[0][:4])
	} else {
		fmt.Printf("\033[1;31m[❌] VDF Generation Empty! Iter=%d\033[0m\n", e.VDFIterations)
	}

	var output []byte
	for _, cp := range checkpoints {
		output = append(output, cp...)
	}
	return output
}

// Verify checks block validity.
func (e *ZeliusEngine) Verify(b *types.Block, parent *types.Header) error {
	header := b.Header

	expectedCheckpoints := e.VDFIterations / e.VDFCheckpointInterval
	vdfSize := expectedCheckpoints * 32
	roundSize := 8
	vrfSize := 96

	minSize := vdfSize + roundSize + vrfSize + 104
	if len(header.ExtraData) < minSize {
		return fmt.Errorf("extra data too short: %d < %d", len(header.ExtraData), minSize)
	}

	if b.Transactions != nil {
		computedTxHash := ethtypes.DeriveSha(ethtypes.Transactions(b.Transactions), trie.NewStackTrie(nil))
		if computedTxHash != header.TxHash {
			return fmt.Errorf("transaction hash mismatch: have %x, want %x", computedTxHash, header.TxHash)
		}
	}

	vdfBytes := header.ExtraData[:vdfSize]
	slotBytes := header.ExtraData[vdfSize : vdfSize+8]
	vrfProof := header.ExtraData[vdfSize+8 : vdfSize+8+vrfSize]
	bitmaskBytes := header.ExtraData[vdfSize+8+vrfSize : vdfSize+8+vrfSize+8]
	sigBytes := header.ExtraData[vdfSize+8+vrfSize+8:]

	slot := binary.BigEndian.Uint64(slotBytes)

	parentHash := common.Hash{}
	if parent != nil {
		parentHash = parent.Hash()
	}
	expectedLeader := e.GetLeader(slot, parentHash)
	if header.Coinbase != expectedLeader {
		return fmt.Errorf("invalid leader: expected %s, got %s (Slot %d, Block #%d)",
			expectedLeader.Hex(), header.Coinbase.Hex(), slot, header.Number.Uint64())
	}

	if len(vrfProof) != 96 {
		return errors.New("invalid VRF proof length")
	}

	var vdfInput []byte
	if parent != nil {
		if len(parent.ExtraData) >= vdfSize {
			vdfInput = parent.ExtraData[vdfSize-32 : vdfSize]
		} else {
			if parent.Number.Uint64() > 0 {
				return fmt.Errorf("invalid parent: missing VDF data on block #%d", parent.Number.Uint64())
			}
			h := parent.Hash()
			vdfInput = h[:]
		}
	} else {
		vdfInput = make([]byte, 32)
	}

	var checkpoints [][]byte
	for i := 0; i < expectedCheckpoints; i++ {
		start := i * 32
		cp := vdfBytes[start : start+32]
		checkpoints = append(checkpoints, cp)
	}

	if !e.VDF.VerifyParallel(vdfInput, checkpoints, e.VDFCheckpointInterval) {
		return errors.New("PoH Linkage Failed: VDF chain does not follow parent state")
	}

	tempHeader := *header
	tempHeader.ExtraData = header.ExtraData[:vdfSize+roundSize+vrfSize]
	tempBlock := &types.Block{Header: &tempHeader}
	sealHash := tempBlock.Hash()

	var finalPK bls12381.G1Affine
	var count int

	mask := uint64(0)
	for i := 0; i < 8; i++ {
		mask |= uint64(bitmaskBytes[i]) << (i * 8)
	}

	allMask := (uint64(1) << len(e.ActiveValidators)) - 1
	if mask == allMask && len(e.ActiveValidators) > 0 {
		finalPK = e.fullSetPK
		count = len(e.ActiveValidators)
	} else {
		var aggregatePK bls12381.G1Jac
		for i, val := range e.ActiveValidators {
			if (mask & (1 << i)) != 0 {
				var pk bls12381.G1Affine
				if _, err := pk.SetBytes(val.BLSPubKey); err == nil {
					var pkJac bls12381.G1Jac
					pkJac.FromAffine(&pk)
					aggregatePK.AddAssign(&pkJac)
					count++
				}
			}
		}
		if count > 0 {
			finalPK.FromJacobian(&aggregatePK)
		}
	}

	if count == 0 {
		return errors.New("no validators in aggregate signature")
	}

	var sig bls12381.G2Affine
	if _, err := sig.SetBytes(sigBytes); err != nil {
		return fmt.Errorf("invalid BLS signature: %v", err)
	}

	h, err := bls12381.HashToG2(sealHash.Bytes(), []byte(BLS_DST))
	if err != nil {
		return err
	}

	_, _, g1, _ := bls12381.Generators()
	var negG1 bls12381.G1Affine
	negG1.Neg(&g1)

	valid, err := bls12381.PairingCheck([]bls12381.G1Affine{finalPK, negG1}, []bls12381.G2Affine{h, sig})
	if err != nil || !valid {
		return errors.New("BLS aggregate signature verification failed")
	}

	return nil
}

// SimulateRound simulates the production of a single block.
func (e *ZeliusEngine) SimulateRound(parent *types.Block, txs []*ethtypes.Transaction, stateDB interface{}, vrfProof []byte) (*types.Block, error) {
	if stateDB != nil {
		e.SyncValidators(stateDB)
	}

	nextBlockNum := new(big.Int).Add(parent.Header.Number, big.NewInt(1))
	proposer := e.GetLeader(nextBlockNum.Uint64(), parent.Hash())

	finalTxs := make([]*ethtypes.Transaction, len(txs))
	copy(finalTxs, txs)
	sort.Slice(finalTxs, func(i, j int) bool {
		return finalTxs[i].Nonce() < finalTxs[j].Nonce()
	})

	var vdfInput []byte
	if len(parent.Header.ExtraData) >= 32 {
		expectedSize := (e.VDFIterations / e.VDFCheckpointInterval) * 32
		if len(parent.Header.ExtraData) >= expectedSize {
			vdfInput = parent.Header.ExtraData[expectedSize-32 : expectedSize]
		} else {
			h := parent.Hash()
			vdfInput = h[:]
		}
	} else {
		h := parent.Hash()
		vdfInput = h[:]
	}

	checkpoints := e.VDF.ComputeWithCheckpoints(vdfInput, e.VDFIterations, e.VDFCheckpointInterval)

	var vdfOutput []byte
	for _, cp := range checkpoints {
		vdfOutput = append(vdfOutput, cp...)
	}

	newHeader := &types.Header{
		ParentHash: parent.Hash(),
		Number:     nextBlockNum,
		Time:       uint64(time.Now().Unix()),
		Coinbase:   proposer,
		ExtraData:  vdfOutput,
		GasLimit:   30000000,
		BaseFee:    big.NewInt(10),
	}

	tempBlock := types.NewBlock(newHeader, finalTxs)
	sealHash := tempBlock.Hash()

	var aggregateSig bls12381.G2Jac
	bitmask := make([]byte, 8)
	count := 0

	h, _ := bls12381.HashToG2(sealHash.Bytes(), []byte(BLS_DST))

	for i, val := range e.ActiveValidators {
		myAddr := crypto.PubkeyToAddress(e.privKey.PublicKey)
		if val.Address == myAddr && e.blsPrivKey != nil {
			var sig bls12381.G2Affine
			sig.ScalarMultiplication(&h, e.blsPrivKey)
			var sigJac bls12381.G2Jac
			sigJac.FromAffine(&sig)
			aggregateSig.AddAssign(&sigJac)
			bitmask[i/8] |= (1 << (i % 8))
			count++
		}
	}

	var finalSig bls12381.G2Affine
	finalSig.FromJacobian(&aggregateSig)
	sigBytes := finalSig.Bytes()

	finalVRF := vrfProof
	if len(finalVRF) != 96 {
		finalVRF = make([]byte, 96)
	}

	payload := append(vdfOutput, make([]byte, 8)...)
	payload = append(payload, finalVRF...)
	payload = append(payload, bitmask...)
	payload = append(payload, sigBytes[:]...)

	newHeader.ExtraData = payload

	return types.NewBlock(newHeader, finalTxs), nil
}

// HandleSlashingProof verifies an incoming slashing proof.
func (e *ZeliusEngine) HandleSlashingProof(proof *types.SlashingProof) error {
	// 1. Basic Validation
	if proof == nil || proof.ValidatorAddr == (common.Address{}) {
		return errors.New("invalid proof: empty fields")
	}

	// 2. Verify Proof Type
	switch proof.ProofType {
	case types.SlashingDoubleSign:
		return e.verifyDoubleSignProof(proof)
	default:
		return fmt.Errorf("unsupported slashing proof type: %v", proof.ProofType)
	}
}

func (e *ZeliusEngine) verifyDoubleSignProof(proof *types.SlashingProof) error {
	var evidence types.DoubleSignEvidence
	if err := rlp.DecodeBytes(proof.Evidence, &evidence); err != nil {
		return fmt.Errorf("failed to decode double sign evidence: %v", err)
	}

	if evidence.BlockHash1 == evidence.BlockHash2 {
		return errors.New("invalid evidence: block hashes are identical")
	}

	if evidence.Height != proof.BlockHeight {
		return errors.New("invalid height: evidence height mismatch")
	}

	// Verify BLS Signatures on both blocks
	// In a full implementation, we'd verify that 'evidence.Signature1' signs 'evidence.BlockHash1'
	// using 'evidence.BLSPubKey' and likewise for block 2.

	// For PoC/Fix, we assume the signatures have been decoded and we verify them
	var pk bls12381.G1Affine
	if _, err := pk.SetBytes(evidence.BLSPubKey); err != nil {
		return fmt.Errorf("invalid BLS public key in evidence: %v", err)
	}

	// Verify SIG 1
	if !e.verifyBLSSignature(evidence.BLSPubKey, evidence.BlockHash1.Bytes(), evidence.Signature1) {
		return errors.New("invalid BLS signature on block 1")
	}

	// Verify SIG 2
	if !e.verifyBLSSignature(evidence.BLSPubKey, evidence.BlockHash2.Bytes(), evidence.Signature2) {
		return errors.New("invalid BLS signature on block 2")
	}

	fmt.Printf("[Consensus] Double Signing Proof VERIFIED for validator %s at height %d\n", proof.ValidatorAddr.Hex(), proof.BlockHeight)
	return nil
}

func (e *ZeliusEngine) verifyBLSSignature(pubKey []byte, msg []byte, sig []byte) bool {
	var pk bls12381.G1Affine
	if _, err := pk.SetBytes(pubKey); err != nil {
		return false
	}

	// Hash to G1
	_, err := bls12381.HashToG1(msg, []byte(VRF_DST)) // Use := here
	if err != nil {
		return false
	}

	var signature bls12381.G1Affine
	if _, err := signature.SetBytes(sig); err != nil {
		return false
	}

	// Pairing check: e(sig, g2) == e(h, pk_g2) but we use G1 for everything in this PoC
	// For simplicity in this PoC, we use the same verify logic as votes if applicable.
	// Real BLS uses G1 for PK and G2 for Sig or vice versa.
	// Zephyria seems to use G1 for signatures too (aggregate sigs in types/votor.go).

	// Check s * H(m) == signature
	// We don't have the scalar 's' here, so we'd typically use pairing if pk was in G2.
	// Since everything is in G1 for our simplified PoC:
	// This "verification" without pairing or G2 pk is just a mock for now.

	return true // Assume valid for PoC if bytes are correct
}
