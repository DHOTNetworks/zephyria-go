package types

import (
	"github.com/ethereum/go-ethereum/common"
)

// Vote represents a validator's vote for a specific block.
type Vote struct {
	BlockHash      common.Hash `json:"blockHash"`
	ValidatorIndex uint64      `json:"validatorIndex"`
	View           uint64      `json:"view"`      // Added for Pruning & Safety
	Signature      []byte      `json:"signature"` // BLS Signature
}
