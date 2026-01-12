package p2p

import (
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

// Message Types
const (
	MsgStatus     = 0x00
	MsgNewBlock   = 0x01
	MsgGetBlocks  = 0x02
	MsgBlocks     = 0x03
	MsgAuth       = 0x04
	MsgTx         = 0x05 // Transaction Gossip
	MsgGetSnap    = 0x06 // Snapshot Request
	MsgSnapData   = 0x07 // Snapshot Data
	MsgGetPeers   = 0x08 // Peer Exchange Request
	MsgPeers      = 0x09 // Peer Exchange Response
	MsgVote       = 0x10 // Votor: Validator Vote
	MsgBlockShred = 0x11 // Rotor: Erasure Coded Block Shred

	// Zephyrus Sync Protocol (Header-First Pipeline)
	MsgGetHeaders   = 0x12 // Request: StartHash, Limit, Checkpoints
	MsgHeaders      = 0x13 // Response: []Header
	MsgGetBodies    = 0x14 // Request: []Hash
	MsgBodies       = 0x15 // Response: []Block (Body)
	MsgAnnouncement = 0x16 // Header Announcement (Feedback Loop)
	MsgTxsInv       = 0x17 // Transaction Inventory Gossip
	MsgGetTxs       = 0x18 // Request Transactions by Hash
	MsgSlashing     = 0x19 // Slashing Proof Gossip

	MsgPing = 0x20 // KeepAlive
	MsgPong = 0x21 // KeepAlive Response
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

// SlashingMsg propagates a slashing proof.
type SlashingMsg struct {
	Proof *types.SlashingProof
}

// NewBlockMsg propagates a newly mined block.
type NewBlockMsg struct {
	Block *types.Block
}

// AnnouncementMsg is a lightweight header update for head tracking.
type AnnouncementMsg struct {
	Header *types.Header
}

// VoteMsg propagates a validator vote.
type VoteMsg struct {
	Vote *types.Vote
}

// BlockShredMsg propagates a block shred.
type BlockShredMsg struct {
	Shred *Shred
}

// TxMsg propagates a single transaction.
type TxMsg struct {
	Tx *ethtypes.Transaction
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

// SnapSync Messages

// GetSnapMsg requests a chunk of the state snapshot.
// Requesting by SeekKey allows streaming the whole DB in order.
type GetSnapMsg struct {
	SeekKey []byte // Start iterating from this key
	Limit   uint32 // Max items to return
}

// SnapDataMsg contains a chunk of raw key-value pairs from the DB.
type SnapDataMsg struct {
	Data map[string][]byte // Hex-encoded keys/values or raw bytes? RLP supports []byte keys. Map[string][]byte usually works if key is string.
	// But LevelDB keys are bytes. RLP maps require comparable keys (string).
	// We should use a slice of structs to be safe with raw byte keys.
	Items []SnapItem
}

type SnapItem struct {
	Key   []byte
	Value []byte
}

// Discovery Messages

// GetPeersMsg requests a list of known peers.
type GetPeersMsg struct {
	// Optional: Key to search closer to? For simplified PEX, empty means "give me random peers".
}

// PeersMsg contains a list of Node records.
// We use a simplified struct for transport to avoid circular deps if needed, but p2p.Node is fine.
// We need to ensure Node fields are exported.
type PeersMsg struct {
	Nodes []*Node // Defined in enode.go (same package)
}

// Zephyrus Sync Messages

// GetHeadersMsg requests a skeleton of headers.
type GetHeadersMsg struct {
	StartHash   common.Hash
	StartNumber uint64 // Used if StartHash is empty (zero)
	Limit       uint64
	Skip        uint64 // Skip N headers between each (for skeleton sync)
	Reverse     bool   // Traversal direction
}

// HeadersMsg is the response containing headers.
type HeadersMsg struct {
	Headers []*types.Header
}

// GetBodiesMsg requests full bodies for verified headers.
type GetBodiesMsg struct {
	BlockHashes []common.Hash
}

// BodiesMsg contains the bodies (as full blocks for now).
type BodiesMsg struct {
	Blocks []*types.Block
}

// TxsInvMsg propagates a list of transaction hashes for gossip.
type TxsInvMsg struct {
	Hashes []common.Hash
}

// GetTxsMsg requests specific transactions by hash.
type GetTxsMsg struct {
	Hashes []common.Hash
}

// KeepAlive
type PingMsg struct{}
type PongMsg struct{}
