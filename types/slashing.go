package types

import (
	"github.com/ethereum/go-ethereum/common"
)

// SlashingProof represents a slashing proof that can be gossiped across the network
type SlashingProof struct {
	ValidatorAddr common.Address // Address of validator to slash
	ProofType     SlashingType   // Type of slashable offense
	Evidence      []byte         // RLP-encoded evidence
	BlockHeight   uint64         // Block height when offense occurred
	Reporter      common.Address // Address submitting the proof
	Signature     []byte         // Reporter's signature over the proof
}
