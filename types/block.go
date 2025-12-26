package types

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
)

// Header represents the block header.
type Header struct {
	ParentHash common.Hash    `json:"parentHash"`
	Number     *big.Int       `json:"number"`
	Time       uint64         `json:"time"`
	VerkleRoot common.Hash    `json:"verkleRoot"` // Root of the Verkle Tree state
	TxHash     common.Hash    `json:"txHash"`     // Hash of the transactions
	Coinbase   common.Address `json:"coinbase"`
	ExtraData  []byte         `json:"extraData"`
	Difficulty *big.Int       `json:"difficulty"`
	GasLimit   uint64         `json:"gasLimit"`
	GasUsed    uint64         `json:"gasUsed"`
	BaseFee    *big.Int       `json:"baseFee"`
}

// Block represents a whole block in the Zephyria blockchain.
type Block struct {
	Header       *Header                 `json:"header"`
	Transactions []*ethtypes.Transaction `json:"transactions"`
}

// NewBlock creates a new block.
func NewBlock(header *Header, txs []*ethtypes.Transaction) *Block {
	return &Block{
		Header:       header,
		Transactions: txs,
	}
}

func (b *Block) Hash() common.Hash {
	return b.Header.Hash()
}

// Hash returns the block header hash (RLP Keccak256).
func (h *Header) Hash() common.Hash {
	if h == nil {
		return common.Hash{}
	}
	bytes, _ := rlp.EncodeToBytes(h)
	return crypto.Keccak256Hash(bytes)
}
