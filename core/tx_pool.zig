const std = @import("std");
const types = @import("types.zig");
const TxList = @import("tx_list.zig").TxList;
const SwissMap = @import("utils").SwissMap;
const RwMux = @import("utils").RwMux;

// Helper functions for SwissMap
inline fn hashAddress(key: types.Address) u64 {
    return std.hash.Wyhash.hash(0, &key.bytes);
}
inline fn eqAddress(a: types.Address, b: types.Address) bool {
    return std.meta.eql(a, b);
}
inline fn hashHash(key: types.Hash) u64 {
    return std.hash.Wyhash.hash(0, &key.bytes);
}
inline fn eqHash(a: types.Hash, b: types.Hash) bool {
    return std.meta.eql(a, b);
}

const AccountMap = SwissMap(types.Address, *TxList, hashAddress, eqAddress);
const TransactionMap = SwissMap(types.Hash, *types.Transaction, hashHash, eqHash);

// Internal state protected by RwMux
const TxPoolState = struct {
    accounts: AccountMap,
    all: TransactionMap,
};

pub const TxPool = struct {
    allocator: std.mem.Allocator,
    // Sharded/RW Lock protecting the state
    // We use RwMux to allow concurrent readers (pending, get_transactions)
    state: RwMux(TxPoolState),

    // Limits
    global_slots: u64,
    account_slots: u64,

    pub fn init(allocator: std.mem.Allocator) TxPool {
        const state = TxPoolState{
            .accounts = AccountMap.init(allocator),
            .all = TransactionMap.init(allocator),
        };

        return TxPool{
            .allocator = allocator,
            .state = RwMux(TxPoolState).init(state),
            .global_slots = 4096,
            .account_slots = 16,
        };
    }

    pub fn deinit(self: *TxPool) void {
        // We need write lock to deinit
        var lock = self.state.write();
        defer lock.unlock();
        var state = lock.mut();

        var it = state.accounts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }

        // Free remaining transactions in the pool
        var tx_it = state.all.iterator();
        while (tx_it.next()) |entry| {
            const tx = entry.value_ptr.*;
            tx.deinit(self.allocator);
            self.allocator.destroy(tx);
        }

        state.accounts.deinit();
        state.all.deinit();
    }

    /// Add adds a transaction to the pool.
    pub fn add(self: *TxPool, tx: *types.Transaction) !bool {
        // Write lock needed
        var lock = self.state.write();
        defer lock.unlock();
        var state = lock.mut();

        const hash = tx.hash();
        if (state.all.get(hash) != null) {
            return false; // Already known
        }

        // Get or create account list
        var list: *TxList = undefined;
        if (state.accounts.getPtr(tx.from)) |ptr| {
            list = ptr.*;
        } else {
            try state.accounts.ensureTotalCapacity(state.accounts.count() + 1);
            const new_list = try self.allocator.create(TxList);
            new_list.* = TxList.init(self.allocator, 0);
            state.accounts.putAssumeCapacity(tx.from, new_list);
            list = new_list;
        }

        // Check if we should replace
        if (list.txs.items.len >= self.account_slots) {
            return false; // Account full
        }

        // Add to List
        const replaced = try list.add(tx);

        // Add to Global Map
        try state.all.ensureTotalCapacity(state.all.count() + 1);
        state.all.putAssumeCapacity(hash, tx);

        return !replaced;
    }

    /// Pending returns all executable transactions.
    pub fn pending(self: *TxPool) ![]*types.Transaction {
        // Read lock allowed
        var lock = self.state.read();
        defer lock.unlock();
        const state = lock.get();

        var batch = std.ArrayList(*types.Transaction).init(self.allocator);
        defer batch.deinit();

        var it = state.accounts.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr.*;
            const ready = list.ready(4096);
            try batch.appendSlice(ready);
        }

        return batch.toOwnedSlice();
    }

    /// get_transactions returns a limited list of pending transactions
    pub fn get_transactions(self: *TxPool, limit: usize) []types.Transaction {
        var lock = self.state.read();
        defer lock.unlock();
        const state = lock.get();

        var txs = std.ArrayListUnmanaged(types.Transaction){};

        var it = state.accounts.iterator();
        var count: usize = 0;
        while (it.next()) |entry| {
            const list = entry.value_ptr.*;
            for (list.txs.items) |tx| {
                if (count >= limit) break;
                // tx is *Transaction. We copy by value.
                txs.append(self.allocator, tx.*) catch break;
                count += 1;
            }
            if (count >= limit) break;
        }
        return txs.toOwnedSlice(self.allocator) catch &[_]types.Transaction{};
    }

    /// remove_executed removes a list of transactions that have been included in a block.
    pub fn remove_executed(self: *TxPool, txs: []const types.Transaction) void {
        var lock = self.state.write();
        defer lock.unlock();
        var state = lock.mut();

        for (txs) |tx| {
            const hash = tx.hash();

            // Remove from Global Map (and optionally free if we owned it)
            // Note: txs contains copies, so we hash them to find original
            if (state.all.get(hash)) |heap_tx| {
                _ = state.all.remove(hash) catch {};
                heap_tx.deinit(self.allocator);
                self.allocator.destroy(heap_tx);
            }

            // Remove from Account List
            if (state.accounts.getPtr(tx.from)) |list_ptr| {
                const list = list_ptr.*;
                // Find and remove from list
                // This is O(N) but N is small (account_slots)
                var i: usize = 0;
                while (i < list.txs.items.len) {
                    if (list.txs.items[i].nonce == tx.nonce) {
                        _ = list.txs.orderedRemove(i);
                        break;
                    } else {
                        i += 1;
                    }
                }
            }
        }
    }
};
