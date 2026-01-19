const std = @import("std");
const core = @import("core");

pub const ValidatorStatus = enum(u8) {
    Active = 0,
    Unbonding = 1,
    Slashed = 2,
    Exited = 3,
};

pub const ValidatorInfo = struct {
    address: core.types.Address,
    stake: u256,
    status: ValidatorStatus,
    bls_pub_key: [48]u8,
    commission: u16,
    activation_block: u64,
    slash_count: u64,
    total_rewards: u256,
    name: []const u8, // Variable length, need to handle carefully in RLP
    website: []const u8,
};

pub const UnbondingRequest = struct {
    amount: u256,
    unlock_block: u64,
    request_block: u64,
};

pub const SlashingType = enum(u8) {
    DoubleSign = 0,
    SurroundVote = 1,
    Unavailability = 2,
};

pub const SlashingRecord = struct {
    validator_addr: core.types.Address,
    slash_type: SlashingType,
    evidence: []const u8,
    slash_amount: u256,
    block_number: u64,
    reporter: core.types.Address,
};

pub const Vote = struct {
    sender: core.types.Address,
    block_hash: core.types.Hash,
    view: u64,
    signature: [96]u8, // BLS G2 signature
};
