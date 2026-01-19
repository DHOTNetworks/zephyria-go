const std = @import("std");
const types = @import("types.zig");
const Blockchain = @import("blockchain.zig").Blockchain;
const Scheduler = @import("scheduler.zig").Scheduler;
const State = @import("state.zig").State;
const NetworkConfig = @import("genesis.zig").NetworkConfig;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    bc: *Blockchain,
    config: NetworkConfig,
    scheduler: Scheduler,

    pub fn init(allocator: std.mem.Allocator, bc: *Blockchain, config: NetworkConfig) Executor {
        return Executor{
            .allocator = allocator,
            .bc = bc,
            .config = config,
            .scheduler = Scheduler.init(allocator),
        };
    }

    pub fn deinit(self: *Executor) void {
        _ = self;
    }

    /// ApplyBlock executes the block transactions and returns receipts + root
    pub fn apply_block(self: *Executor, state_obj: *State, header: *types.Header, txs: []*types.Transaction) !types.Hash {
        // 1. Group transactions into waves using Aquarius Scheduler
        const waves = try self.scheduler.schedule(txs, state_obj);
        defer {
            for (waves) |wave| self.allocator.free(wave);
            self.allocator.free(waves);
        }

        var block_gas_used: u64 = 0;
        var total_fees = @as(u256, 0);

        // 2. Execute Waves sequentially (Parallelism simulation)
        for (waves) |wave| {
            // Wave processing: Inside a wave, transactions are independent
            for (wave) |tx| {
                const intrinsic = calculate_intrinsic_gas(tx);
                if (tx.gas_limit < intrinsic) continue; // Should have been caught by TxPool

                // Create isolated overlay for the transaction
                var overlay = try state_obj.new_overlay();
                defer overlay.deinit();

                // Aquarius Auto-Binding: Redirect if needed
                var effective_to = tx.to;
                if (tx.to) |target| {
                    if (state_obj.is_program_account(target)) {
                        effective_to = self.scheduler.derive_data_address(tx.from, target);
                    }
                }

                // Execute Logic (Stub: Simple balance transfer for now)
                const gas_used = intrinsic; // Assume only intrinsic for now
                const fee = @as(u256, gas_used) * tx.gas_price;

                // Deduct fee from sender
                try overlay.add_balance(tx.from, -@as(i256, @intCast(fee)));
                try overlay.set_nonce(tx.from, tx.nonce + 1);

                if (effective_to) |to| {
                    try overlay.add_balance(to, @as(i256, @intCast(tx.value)));
                    try overlay.add_balance(tx.from, -@as(i256, @intCast(tx.value)));
                }

                // Deterministic Merge: Apply transaction result to block state
                try overlay.commit();

                block_gas_used += gas_used;
                total_fees += fee;
            }
        }

        // 3. Finalize: Rewards and Economics
        const reward = @as(u256, 10_000_000_000_000_000_000); // 10 ZEE
        try state_obj.add_balance(header.coinbase, @as(i256, @intCast(reward + total_fees)));

        // Update block header stats
        header.gas_used = block_gas_used;

        // Intermediate Root (Stub: Return zero or mock)
        return types.Hash.zero();
    }

    pub fn calculate_intrinsic_gas(tx: *const types.Transaction) u64 {
        var gas: u64 = 21000;
        if (tx.to == null) gas += 32000;
        for (tx.data) |b| {
            gas += if (b == 0) @as(u64, 4) else @as(u64, 16);
        }
        return gas;
    }
};
