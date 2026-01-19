const std = @import("std");
pub const types = @import("types.zig");
pub const BigInt = @import("bigint.zig").BigInt;
pub const state = @import("state.zig");
pub const account = @import("account.zig");
pub const genesis = @import("genesis.zig");
pub const tx_list = @import("tx_list.zig");
pub const tx_pool = @import("tx_pool.zig");
pub const blockchain = @import("blockchain.zig");
pub const scheduler = @import("scheduler.zig");
pub const executor = @import("executor.zig");
pub const tx_decode = @import("tx_decode.zig");

// Re-exports
pub const TxList = tx_list.TxList;
pub const TxPool = tx_pool.TxPool;
pub const Blockchain = blockchain.Blockchain;
pub const Scheduler = scheduler.Scheduler;
pub const Executor = executor.Executor;
pub const State = state.State;

pub fn init() void {
    std.debug.print("Core module initialized\n", .{});
}
