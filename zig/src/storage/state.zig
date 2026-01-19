const std = @import("std");
const VerkleTrie = @import("verkle/trie.zig").VerkleTrie;
const DB = @import("lsm/db.zig").DB;

pub const Account = extern struct {
    nonce: u64,
    balance: u256,
    storage_root: [32]u8,
    code_hash: [32]u8,
};

pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    trie: VerkleTrie,
    db: *DB,

    pub fn init(allocator: std.mem.Allocator, db: *DB) !GlobalState {
        // Initialize Verkle Trie with the DB
        const trie = try VerkleTrie.init(allocator, db.asAbstractDB());
        return GlobalState{
            .allocator = allocator,
            .trie = trie,
            .db = db,
        };
    }

    pub fn deinit(self: *GlobalState) void {
        self.trie.deinit();
    }

    // Account Access
    pub fn getAccount(self: *GlobalState, address: [20]u8) !?Account {
        // Key for account in trie: address padded to 32 bytes?
        // Or hash of address? For Verkle, we usually map address -> commitment.
        // For this implementation, we'll use address zero-padded to 32 bytes as the key.
        var key: [32]u8 = [_]u8{0} ** 32;
        @memcpy(key[0..20], address[0..]);

        if (try self.trie.get(key)) |data| {
            defer self.allocator.free(data);
            if (data.len != @sizeOf(Account)) return null;
            return std.mem.bytesToValue(Account, data[0..@sizeOf(Account)]);
        }
        return null;
    }

    pub fn putAccount(self: *GlobalState, address: [20]u8, account: Account) !void {
        var key: [32]u8 = [_]u8{0} ** 32;
        @memcpy(key[0..20], address[0..]);

        const data = std.mem.asBytes(&account);
        try self.trie.put(key, data);
    }

    // Storage Access (contract storage)
    // We need to mix address and storage key to form a unique key in the global trie,
    // or use the account's storage_root for a separate trie.
    // Given the singular state goal, a single trie with prefixing is better for "statelessness" (one root).
    // Verkle trees usually have a specific key derivation strategy.
    // For now: Hash(address ++ key) -> Trie Key.
    pub fn getStorage(self: *GlobalState, address: [20]u8, key: [32]u8) ![32]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&address);
        hasher.update(&key);
        var path: [32]u8 = undefined;
        hasher.final(&path);

        if (try self.trie.get(path)) |data| {
            defer self.allocator.free(data);
            if (data.len == 32) {
                var val: [32]u8 = undefined;
                @memcpy(&val, data[0..32]);
                return val;
            }
        }
        return [_]u8{0} ** 32;
    }

    pub fn putStorage(self: *GlobalState, address: [20]u8, key: [32]u8, value: [32]u8) !void {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&address);
        hasher.update(&key);
        var path: [32]u8 = undefined;
        hasher.final(&path);

        try self.trie.put(path, &value);
    }

    // Commit changes to underlying Storage/LSM
    pub fn commit(self: *GlobalState) !void {
        try self.trie.commit();
        try self.db.flush();
    }
};
