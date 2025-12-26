package types

import (
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

// Receipt represents the results of a transaction.
type Receipt struct {
	// Consensus fields
	PostState         []byte          `json:"root"`
	Status            uint64          `json:"status"`
	CumulativeGasUsed uint64          `json:"cumulativeGasUsed"`
	Bloom             ethtypes.Bloom  `json:"logsBloom"`
	Logs              []*ethtypes.Log `json:"logs"`

	// Implementation fields (don't need to be persisted if derived, but help API)
	TxHash          common.Hash    `json:"transactionHash"`
	ContractAddress common.Address `json:"contractAddress"`
	GasUsed         uint64         `json:"gasUsed"`
}
