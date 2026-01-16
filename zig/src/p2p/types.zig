const std = @import("std");
const core = @import("core");

// Message Codes
pub const MsgStatus: u64 = 0x00;
pub const MsgNewBlock: u64 = 0x01;
pub const MsgGetBlocks: u64 = 0x02;
pub const MsgBlocks: u64 = 0x03;
pub const MsgTx: u64 = 0x04;
pub const MsgVote: u64 = 0x05;
pub const MsgGetHeaders: u64 = 0x06;
pub const MsgHeaders: u64 = 0x07;
pub const MsgGetBodies: u64 = 0x08;
pub const MsgBodies: u64 = 0x09;
pub const MsgAuth: u64 = 0x0A;
pub const MsgSlashing: u64 = 0x0B;
pub const MsgGetPeers: u64 = 0x0C;
pub const MsgPeers: u64 = 0x0D;

pub const StatusMsg = struct {
    chain_id: u64,
    genesis_hash: core.types.Hash,
    head_hash: core.types.Hash,
    head_number: u64,
    challenge: [32]u8, // random bytes for auth
};

pub const NewBlockMsg = struct {
    block: core.types.Block,
    total_difficulty: u256, // or similar
    hop_count: u32,
};

pub const GetBlocksMsg = struct {
    start_hash: core.types.Hash,
    limit: u64,
    direction: u8, // 0 = up, 1 = down?
};

pub const BlocksMsg = struct {
    blocks: []core.types.Block,
};

pub const TxMsg = struct {
    tx: core.types.Transaction,
};

pub const VoteMsg = struct {
    block_hash: core.types.Hash,
    view: u64,
    signature: [96]u8, // BLS G2
    validator_idx: u64,
};

pub const AuthMsg = struct {
    signature: []const u8, // ECDSA signature of challenge
    public_key: []const u8, // ECDSA public key
};

pub const SlashingMsg = struct {
    proof_data: []const u8, // Opaque proof bytes for now
};

pub const PeersMsg = struct {
    nodes: []NodeInfo,
};

pub const NodeInfo = struct {
    id: [64]u8, // Node ID
    ip: []const u8,
    port: u16,
};
