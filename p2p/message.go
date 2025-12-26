package p2p

import (
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
)

// Message Types
const (
	MsgStatus    = 0x00
	MsgNewBlock  = 0x01
	MsgGetBlocks = 0x02
	MsgBlocks    = 0x03
	MsgAuth      = 0x04 // Zelius Shield Handshake
)

// StatusMsg is the first message exchanged (Handshake).
type StatusMsg struct {
	ProtocolVersion uint32
	NetworkID       uint64
	GenesisHash     common.Hash
	HeadHash        common.Hash
	HeadNumber      uint64
	Challenge       []byte // Random Nonce for Zelius Shield Handshake
}

// NewBlockMsg propagates a newly mined block.
type NewBlockMsg struct {
	Block *types.Block
}

// GetBlocksMsg requests blocks starting from a hash (or number).
// Simple sync: Start from Hash, get N blocks.
type GetBlocksMsg struct {
	StartHash common.Hash
	Limit     uint64
}

// BlocksMsg is the response to GetBlocksMsg.
type BlocksMsg struct {
	Blocks []*types.Block
}

// AuthMsg is sent after StatusMsg to prove identity.
// Zelius Shield: "Stake-Gated Access"
type AuthMsg struct {
	Signature []byte // Signature of the Challenge Nonce
	PublicKey []byte // Compressed Public Key
}
