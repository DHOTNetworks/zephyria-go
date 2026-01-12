package consensus

import (
	"crypto/ecdsa"
	"math/big"

	"zephyria/consensus/vdf"

	bls12381 "github.com/consensys/gnark-crypto/ecc/bls12-381"
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

const BLS_DST = "ZEPHYRIA-BLOCK-SIGNATURE"
const VRF_DST = "ZEPHYRIA-VRF"

// ZeliusEngine implements the Zelius Consensus (PoS with Leader Schedule).
type ZeliusEngine struct {
	Validators []*Validator
	f          int // fault tolerance threshold

	// Local identity
	privKey *ecdsa.PrivateKey

	// Non-compliance tracking
	NonCompliantValidators map[common.Address]int

	// Zelius Specifics
	LeaderSchedule   map[uint64]common.Address // Block -> Leader
	EpochLength      uint64                    // Number of blocks per epoch
	CurrentEpoch     uint64
	ActiveValidators []*Validator // Validators fixed for the current epoch
	CurrentEpochSeed common.Hash  // Seed for the current epoch's randomness

	// BLS Identity
	blsPrivKey *big.Int

	// Optimizations
	fullSetPK bls12381.G1Affine // Cached PK of all ActiveValidators

	// VDF Configuration
	VDFIterations         int
	VDFCheckpointInterval int
	VDF                   *vdf.VDF
	Metronome             *vdf.Metronome
}

// Validator represents a node in the consensus.
type Validator struct {
	Address   common.Address
	Stake     *big.Int
	BLSPubKey []byte // Compressed P1Affine (48 bytes)
}

// Batch represents a proposal from a validator.
type Batch struct {
	Proposer common.Address
	Txs      []*ethtypes.Transaction
}
