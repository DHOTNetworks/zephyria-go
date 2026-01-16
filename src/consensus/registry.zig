const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

const State = core.State;

pub const ValidatorRegistry = struct {
    staking_addr: core.types.Address,
    validator_addr: core.types.Address,
    // allocator: std.mem.Allocator,

    pub fn init(staking_addr: core.types.Address, validator_addr: core.types.Address) ValidatorRegistry {
        return ValidatorRegistry{
            .staking_addr = staking_addr,
            .validator_addr = validator_addr,
        };
    }

    fn validator_info_key(self: *const ValidatorRegistry, addr: core.types.Address) core.types.Hash {
        _ = self;
        // Crypto.Keccak256(addr + "INFO")
        // TODO: Implement actual Keccak hashing
        var buf: [32]u8 = undefined;
        @memcpy(buf[0..20], addr[0..20]);
        return buf;
    }

    pub fn get_validator_info(self: *const ValidatorRegistry, world_state: *State, addr: core.types.Address) ?types.ValidatorInfo {
        const key = self.validator_info_key(addr);
        const data = world_state.get_verkle_value(key);
        if (data) |d| {
            defer world_state.allocator.free(d);
            if (d.len == 0) return null;
            // TODO: RLP Decode
            return null;
        }
        return null;
    }

    pub fn register_validator(
        self: *ValidatorRegistry,
        world_state: *State,
        addr: core.types.Address,
        stake: u256,
        bls_pub_key: [48]u8,
        commission: u16,
        block_num: u64,
    ) !void {
        // Validate inputs
        if (commission > 10000) return error.CommissionTooHigh;

        // Check existing
        if (self.get_validator_info(world_state, addr) != null) return error.ValidatorAlreadyRegistered;

        const info = types.ValidatorInfo{
            .address = addr,
            .stake = stake,
            .status = .Active,
            .bls_pub_key = bls_pub_key,
            .commission = commission,
            .activation_block = block_num,
            .slash_count = 0,
            .total_rewards = 0,
            .name = "",
            .website = "",
        };

        // TODO: RLP Encode and SetState
        // self.set_validator_info(statedb, info);
        _ = info;
    }
};
