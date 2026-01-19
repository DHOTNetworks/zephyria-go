const std = @import("std");
const types = @import("types.zig");

/// TxList manages a list of transactions for a single account, sorted by nonce.
pub const TxList = struct {
    allocator: std.mem.Allocator,
    txs: std.ArrayListUnmanaged(*types.Transaction),
    nonce: u64, // Expected state nonce

    pub fn init(allocator: std.mem.Allocator, nonce: u64) TxList {
        return TxList{
            .allocator = allocator,
            .txs = .{},
            .nonce = nonce,
        };
    }

    pub fn deinit(self: *TxList) void {
        self.txs.deinit(self.allocator);
    }

    /// Add inserts a transaction into the sorted list.
    /// Returns true if it replaced an existing transaction (same nonce).
    /// Returns error if nonce is lower than current state nonce.
    pub fn add(self: *TxList, tx: *types.Transaction) !bool {
        if (tx.nonce < self.nonce) {
            return error.NonceTooLow;
        }

        // Check for existing nonce to replace
        for (self.txs.items, 0..) |existing, i| {
            if (existing.nonce == tx.nonce) {
                // Replacement Logic (Gas Price Bump check typically here)
                // For now, simpler replacement:
                // Typically we check if new price > old price * 1.1
                // We'll skip complex check for this port step.
                self.txs.items[i] = tx;
                return true;
            }
            if (existing.nonce > tx.nonce) {
                // Insert before
                try self.txs.insert(self.allocator, i, tx);
                return false;
            }
        }

        // Append at end
        try self.txs.append(self.allocator, tx);
        return false;
    }

    /// Forward advances the expected nonce (e.g. after block inclusion).
    /// Removes transactions with nonce < new_nonce.
    pub fn forward(self: *TxList, new_nonce: u64) void {
        self.nonce = new_nonce;

        while (self.txs.items.len > 0) {
            if (self.txs.items[0].nonce < new_nonce) {
                // Remove front
                _ = self.txs.orderedRemove(0);
            } else {
                break;
            }
        }
    }

    /// Ready returns a slice of transactions that are executable (contiguous nonces starting from self.nonce).
    /// The returned slice is owned by the list internal buffer (reference valid until modification).
    pub fn ready(self: *TxList, cap: usize) []const *types.Transaction {
        var count: usize = 0;
        var next_nonce = self.nonce;

        for (self.txs.items) |tx| {
            if (count >= cap) break;
            if (tx.nonce == next_nonce) {
                count += 1;
                next_nonce += 1;
            } else {
                // Gap found
                break;
            }
        }
        return self.txs.items[0..count];
    }

    pub fn len(self: *TxList) usize {
        return self.txs.items.len;
    }

    pub fn empty(self: *TxList) bool {
        return self.txs.items.len == 0;
    }
};
