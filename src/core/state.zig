const std = @import("std");
const types = @import("types.zig");
const storage = @import("storage");
const VerkleTrie = storage.verkle.trie.VerkleTrie;

/// State represents the World State of Zephyria.
/// It wraps the NOMT (Verkle Trie) and provides account-level abstractions.
pub const State = struct {
    allocator: std.mem.Allocator,
    trie: *VerkleTrie,

    pub fn init(allocator: std.mem.Allocator, trie: *VerkleTrie) State {
        return State{
            .allocator = allocator,
            .trie = trie,
        };
    }

    pub fn deinit(self: *State) void {
        _ = self;
    }

    // --- Key Derivation (NOMT/Verkle standard) ---

    pub fn account_stem(addr: types.Address) [31]u8 {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&addr.bytes, &h, .{});
        var stem: [31]u8 = undefined;
        @memcpy(&stem, h[0..31]);
        return stem;
    }

    pub fn nonce_key(addr: types.Address) [32]u8 {
        var key: [32]u8 = undefined;
        @memcpy(key[0..31], &account_stem(addr));
        key[31] = 0x00;
        return key;
    }

    pub fn balance_key(addr: types.Address) [32]u8 {
        var key: [32]u8 = undefined;
        @memcpy(key[0..31], &account_stem(addr));
        key[31] = 0x01;
        return key;
    }

    pub fn code_hash_key(addr: types.Address) [32]u8 {
        var key: [32]u8 = undefined;
        @memcpy(key[0..31], &account_stem(addr));
        key[31] = 0x02;
        return key;
    }

    // --- Account API ---

    pub fn get_balance(self: *State, addr: types.Address) u256 {
        const key = balance_key(addr);
        const data = self.trie.get(key) catch return 0;
        if (data) |d| {
            defer self.allocator.free(d);
            if (d.len < 32) return 0;
            return std.mem.readInt(u256, d[32 - @min(d.len, 32) .. 32][0..32], .big);
        }
        return 0;
    }

    pub fn set_balance(self: *State, addr: types.Address, balance: u256) !void {
        const key = balance_key(addr);
        var buf: [32]u8 = undefined;
        std.mem.writeInt(u256, &buf, balance, .big);
        try self.trie.put(key, &buf);
    }

    pub fn get_nonce(self: *State, addr: types.Address) u64 {
        const key = nonce_key(addr);
        const data = self.trie.get(key) catch return 0;
        if (data) |d| {
            defer self.allocator.free(d);
            if (d.len < 8) return 0;
            return std.mem.readInt(u64, d[8 - @min(d.len, 8) .. 8][0..8], .big);
        }
        return 0;
    }

    pub fn set_nonce(self: *State, addr: types.Address, nonce: u64) !void {
        const key = nonce_key(addr);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, nonce, .big);
        try self.trie.put(key, &buf);
    }

    pub fn add_balance(self: *State, addr: types.Address, amount: i256) !void {
        const current = self.get_balance(addr);
        const new_bal = if (amount >= 0) current +% @as(u256, @intCast(amount)) else current -% @as(u256, @intCast(-amount));
        try self.set_balance(addr, new_bal);
    }

    pub fn get_verkle_value(self: *State, key: [32]u8) ?[]const u8 {
        const data = self.trie.get(key) catch return null;
        return data; // Caller must free
    }

    pub fn set_verkle_value(self: *State, key: [32]u8, value: []const u8) !void {
        try self.trie.put(key, value);
    }

    pub fn is_program_account(self: *State, addr: types.Address) bool {
        _ = self;
        _ = addr;
        return false; // Stub
    }

    // --- Overlay / Isolation ---

    pub fn new_overlay(self: *State) !Overlay {
        return Overlay.init(self.allocator, self);
    }
};

/// Overlay handles per-transaction state changes.
/// This fulfills the need for atomic reverts without thick Go-style journaling.
pub const Overlay = struct {
    allocator: std.mem.Allocator,
    base: *State,
    dirty: std.AutoHashMap([32]u8, []const u8),

    pub fn init(allocator: std.mem.Allocator, base: *State) Overlay {
        return Overlay{
            .allocator = allocator,
            .base = base,
            .dirty = std.AutoHashMap([32]u8, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Overlay) void {
        var it = self.dirty.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.dirty.deinit();
    }

    pub fn get_balance(self: *Overlay, addr: types.Address) u256 {
        const key = State.balance_key(addr);
        if (self.dirty.get(key)) |d| {
            return std.mem.readInt(u256, d[0..32], .big);
        }
        return self.base.get_balance(addr);
    }

    pub fn set_balance(self: *Overlay, addr: types.Address, balance: u256) !void {
        const key = State.balance_key(addr);
        var buf: [32]u8 = undefined;
        std.mem.writeInt(u256, &buf, balance, .big);

        const g = try self.dirty.getOrPut(key);
        if (g.found_existing) self.allocator.free(g.value_ptr.*);
        g.value_ptr.* = try self.allocator.dupe(u8, &buf);
    }

    pub fn get_nonce(self: *Overlay, addr: types.Address) u64 {
        const key = State.nonce_key(addr);
        if (self.dirty.get(key)) |d| {
            return std.mem.readInt(u64, d[0..8], .big);
        }
        return self.base.get_nonce(addr);
    }

    pub fn set_nonce(self: *Overlay, addr: types.Address, nonce: u64) !void {
        const key = State.nonce_key(addr);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, nonce, .big);

        const g = try self.dirty.getOrPut(key);
        if (g.found_existing) self.allocator.free(g.value_ptr.*);
        g.value_ptr.* = try self.allocator.dupe(u8, &buf);
    }

    pub fn add_balance(self: *Overlay, addr: types.Address, amount: i256) !void {
        const current = self.get_balance(addr);
        const new_bal = if (amount >= 0) current +% @as(u256, @intCast(amount)) else current -% @as(u256, @intCast(-amount));
        try self.set_balance(addr, new_bal);
    }

    pub fn commit(self: *Overlay) !void {
        var it = self.dirty.iterator();
        while (it.next()) |entry| {
            try self.base.trie.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        // Dirty map is cleared on deinit or manually
    }
};
