const std = @import("std");
const core_types = @import("types.zig");

pub const SystemParams = struct {
    vdf_iterations: u64,
    vdf_interval: u64,
    slot_time: u64,
    epoch_length: u64,
    staking_addr: core_types.Address,
    reward_addr: core_types.Address,
    validator_addr: core_types.Address,
    randomness_addr: core_types.Address,
    default_gas_limit: u64,
    default_base_fee: u256,
};

pub const NetworkConfig = struct {
    chain_id: u256,
    genesis_time: u64,
    genesis_hash: core_types.Hash,
    gas_limit: u64,
    base_fee: ?u256,
    coinbase: core_types.Address,
    system_params: SystemParams,
};

pub const GenesisAlloc = struct { addr: core_types.Address, balance: u256 };

pub const Genesis = struct {
    config: NetworkConfig,
    // Using a slice for initial allocations for easier RLP/iteration
    alloc: []const GenesisAlloc,
};

// Hardcoded values from Go implementation
pub const default_dev_key = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

pub fn getNetworkConfig(network: []const u8) NetworkConfig {
    if (std.mem.eql(u8, network, "devnet")) {
        return NetworkConfig{
            .chain_id = 99999,
            .genesis_time = 1735689600, // 2025-01-01
            .genesis_hash = core_types.Hash.zero(), // To be computed
            .gas_limit = 60000000,
            .base_fee = 1000000000,
            .coinbase = parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
            .system_params = SystemParams{
                .vdf_iterations = 1100000,
                .vdf_interval = 15000,
                .slot_time = 12,
                .epoch_length = 32,
                .staking_addr = parseAddress("0x0000000000000000000000000000000000001000"),
                .reward_addr = parseAddress("0x0000000000000000000000000000000000002000"),
                .validator_addr = parseAddress("0x0000000000000000000000000000000000003000"),
                .randomness_addr = parseAddress("0x0000000000000000000000000000000000004000"),
                .default_gas_limit = 60000000,
                .default_base_fee = 1000000000,
            },
        };
    }
    return NetworkConfig{
        .chain_id = 1,
        .genesis_time = 0,
        .genesis_hash = core_types.Hash.zero(),
        .gas_limit = 30000000,
        .base_fee = null,
        .coinbase = core_types.Address.zero(),
        .system_params = SystemParams{
            .vdf_iterations = 10000,
            .vdf_interval = 1000,
            .slot_time = 12,
            .epoch_length = 32,
            .staking_addr = parseAddress("0x0000000000000000000000000000000000001000"),
            .reward_addr = parseAddress("0x0000000000000000000000000000000000002000"),
            .validator_addr = parseAddress("0x0000000000000000000000000000000000003000"),
            .randomness_addr = parseAddress("0x0000000000000000000000000000000000004000"),
            .default_gas_limit = 30000000,
            .default_base_fee = 1000000000,
        },
    };
}

/// applyGenesis initializes the state with genesis allocations and returns the genesis block
pub fn applyGenesis(allocator: std.mem.Allocator, trie: anytype, genesis: Genesis) !*core_types.Block {
    const state = @import("state.zig");
    // 1. Apply Initial Allocations
    for (genesis.alloc) |entry| {
        const key = state.State.balance_key(entry.addr);
        var balance_bytes = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &balance_bytes, entry.balance, .big);

        try trie.put(key, &balance_bytes);
    }

    // 2. Commit State to get root
    try trie.commit();
    const verkle_root_arr = trie.rootHash();

    // 3. Construct Header
    const header = core_types.Header{
        .parent_hash = core_types.Hash.zero(),
        .number = 0,
        .time = genesis.config.genesis_time,
        .verkle_root = core_types.Hash{ .bytes = verkle_root_arr },
        .tx_hash = core_types.Hash.zero(), // Empty txs
        .coinbase = genesis.config.coinbase,
        .extra_data = &[_]u8{},
        .gas_limit = genesis.config.gas_limit,
        .gas_used = 0,
        .base_fee = genesis.config.base_fee orelse 1000000000,
    };

    const block = try allocator.create(core_types.Block);
    block.* = core_types.Block{
        .header = header,
        .transactions = &[_]core_types.Transaction{},
    };

    return block;
}

fn parseAddress(hex: []const u8) core_types.Address {
    var addr = core_types.Address.zero();
    if (hex.len >= 2 and hex[0] == '0' and hex[1] == 'x') {
        const hex_str = hex[2..];
        var i: usize = 0;
        while (i < @min(hex_str.len / 2, 20)) : (i += 1) {
            const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch 0;
            const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch 0;
            addr.bytes[i] = (hi << 4) | lo;
        }
    }
    return addr;
}

/// getDefaultAlloc returns the default genesis allocations for devnet
pub fn getDefaultAlloc() [4]GenesisAlloc {
    // 1. Dev account: 100,000 ZEE (100k * 10^18)
    const dev_addr = parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const dev_balance: u256 = 100_000 * 1_000_000_000_000_000_000;

    // 2-4. System contracts: 1 ZEE each for visibility
    const sys_balance: u256 = 1_000_000_000_000_000_000;
    const staking_addr = parseAddress("0x0000000000000000000000000000000000001000");
    const reward_addr = parseAddress("0x0000000000000000000000000000000000002000");
    const validator_addr = parseAddress("0x0000000000000000000000000000000000003000");

    return [_]GenesisAlloc{
        .{ .addr = dev_addr, .balance = dev_balance },
        .{ .addr = staking_addr, .balance = sys_balance },
        .{ .addr = reward_addr, .balance = sys_balance },
        .{ .addr = validator_addr, .balance = sys_balance },
    };
}
