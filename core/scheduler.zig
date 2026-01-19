const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{
            .allocator = allocator,
        };
    }

    /// Groups transactions into waves that can be executed in parallel.
    /// Each wave contains transactions that do not have conflicting Read/Write sets.
    pub fn schedule(self: *Scheduler, txs: []*types.Transaction, state_obj: *state.State) ![][]*types.Transaction {
        if (txs.len == 0) return try self.allocator.alloc([]*types.Transaction, 0);

        var waves = std.ArrayListUnmanaged([]*types.Transaction){};
        errdefer {
            for (waves.items) |w| self.allocator.free(w);
            waves.deinit(self.allocator);
        }

        // Global tracked reads/writes for the ACTIVE wave
        var global_writes = std.StringHashMap(void).init(self.allocator);
        defer self.free_kv(&global_writes);
        var global_reads = std.StringHashMap(void).init(self.allocator);
        defer self.free_kv(&global_reads);

        var current_wave = std.ArrayListUnmanaged(*types.Transaction){};
        defer current_wave.deinit(self.allocator);

        // Use a list to track transactions that need scheduling
        var pending = std.ArrayListUnmanaged(*types.Transaction){};
        defer pending.deinit(self.allocator);
        try pending.appendSlice(self.allocator, txs);

        var next_pending = std.ArrayListUnmanaged(*types.Transaction){};
        defer next_pending.deinit(self.allocator);

        while (pending.items.len > 0) {
            for (pending.items) |tx| {
                const sender = tx.from;
                const recipient = tx.to orelse types.Address.zero();

                // 1. Identify local Read/Write sets for this transaction
                var tx_writes = std.ArrayListUnmanaged([32]u8){};
                defer tx_writes.deinit(self.allocator);
                var tx_reads = std.ArrayListUnmanaged([32]u8){};
                defer tx_reads.deinit(self.allocator);

                // Senders always write Nonce and Balance (for gas payment)
                try tx_writes.append(self.allocator, state.State.nonce_key(sender));
                try tx_writes.append(self.allocator, state.State.balance_key(sender));

                if (tx.to) |target| {
                    if (state_obj.is_program_account(target)) {
                        // Aquarius: It's a contract. We write to the User's Data Shard.
                        // For parity, we derive the data address and lock its account stem.
                        const data_addr = self.derive_data_address(sender, target);
                        try tx_writes.append(self.allocator, state.State.balance_key(data_addr));

                        // We READ from the program code
                        try tx_reads.append(self.allocator, state.State.code_hash_key(target));
                    } else if (tx.value > 0) {
                        try tx_writes.append(self.allocator, state.State.balance_key(recipient));
                    }
                }

                // 2. Conflict Detection
                var conflict = false;
                for (tx_writes.items) |w| {
                    if (global_writes.contains(&w) or global_reads.contains(&w)) {
                        conflict = true;
                        break;
                    }
                }
                if (!conflict) {
                    for (tx_reads.items) |r| {
                        if (global_writes.contains(&r)) {
                            conflict = true;
                            break;
                        }
                    }
                }

                if (!conflict) {
                    // Accept into wave
                    try current_wave.append(self.allocator, tx);
                    for (tx_writes.items) |w| try global_writes.put(try self.allocator.dupe(u8, &w), {});
                    for (tx_reads.items) |r| try global_reads.put(try self.allocator.dupe(u8, &r), {});
                } else {
                    try next_pending.append(self.allocator, tx);
                }
            }

            if (current_wave.items.len == 0 and next_pending.items.len > 0) {
                // Deadlock safety: if NO transactions could be scheduled,
                // take the first one serial.
                const forced = next_pending.orderedRemove(0);
                try current_wave.append(self.allocator, forced);
            }

            // Finalize current wave
            try waves.append(self.allocator, try current_wave.toOwnedSlice(self.allocator));

            // Prepare for next wave
            self.free_kv(&global_writes);
            self.free_kv(&global_reads);

            pending.clearRetainingCapacity();
            try pending.appendSlice(self.allocator, next_pending.items);
            next_pending.clearRetainingCapacity();
        }

        return try waves.toOwnedSlice(self.allocator);
    }

    /// Aquarius helper: derives a deterministic data address for (User, Program)
    pub fn derive_data_address(self: *Scheduler, user: types.Address, program: types.Address) types.Address {
        _ = self;
        var h: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
        hasher.update(&user.bytes);
        hasher.update(&program.bytes);
        hasher.final(&h);

        var addr: types.Address = undefined;
        @memcpy(&addr.bytes, h[12..32]); // Take last 20 bytes
        return addr;
    }

    fn free_kv(self: *Scheduler, map: *std.StringHashMap(void)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        map.clearRetainingCapacity();
    }
};
