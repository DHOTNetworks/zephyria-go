const std = @import("std");
const rlp = @import("encoding").rlp;

pub const Address = extern struct {
    bytes: [20]u8,

    pub fn format(self: Address, writer: anytype) !void {
        var buf: [42]u8 = undefined;
        _ = @import("utils").hex.encodeBuffer(&buf, &self.bytes) catch unreachable;
        try writer.writeAll(&buf);
    }

    pub fn zero() Address {
        return .{ .bytes = [_]u8{0} ** 20 };
    }
};

pub const Hash = extern struct {
    bytes: [32]u8,

    pub fn format(self: Hash, writer: anytype) !void {
        var buf: [66]u8 = undefined;
        _ = @import("utils").hex.encodeBuffer(&buf, &self.bytes) catch unreachable;
        try writer.writeAll(&buf);
    }

    pub fn zero() Hash {
        return .{ .bytes = [_]u8{0} ** 32 };
    }
};
pub const Header = struct {
    parent_hash: Hash,
    number: u64,
    time: u64,
    verkle_root: Hash,
    tx_hash: Hash,
    coinbase: Address,
    extra_data: []const u8,
    gas_limit: u64,
    gas_used: u64,
    base_fee: u256,

    pub fn rlp_encode(self: Header, allocator: std.mem.Allocator) ![]u8 {
        return try rlp.encode(allocator, self);
    }

    pub fn rlp_decode(allocator: std.mem.Allocator, data: []const u8) !Header {
        return try rlp.decode(allocator, Header, data);
    }

    pub fn deinit(self: Header, allocator: std.mem.Allocator) void {
        allocator.free(self.extra_data);
    }
};

pub const Transaction = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    // NOTE: 'from' is NOT part of RLP-encoded transactions.
    // It must be derived from the signature (v, r, s) after decoding.
    // For transactions created in-memory, it can be set directly.
    from: Address,
    to: ?Address,
    value: u256,
    data: []const u8,
    v: u256,
    r: u256,
    s: u256,

    pub fn hash(self: *const Transaction) Hash {
        // Real hash would be keccak256 of rlp(nonce, price, limit, to, value, data, v, r, s)
        var h_res = Hash.zero();
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});

        const ally = std.heap.page_allocator;
        const encoded = rlp.encode(ally, self.*) catch return h_res;
        defer ally.free(encoded);

        hasher.update(encoded);
        hasher.final(&h_res.bytes);
        return h_res;
    }

    pub fn deinit(self: Transaction, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const Block = struct {
    header: Header,
    transactions: []Transaction,

    pub fn rlp_encode(self: Block, allocator: std.mem.Allocator) ![]u8 {
        return try rlp.encode(allocator, self);
    }

    pub fn rlp_decode(allocator: std.mem.Allocator, data: []const u8) !Block {
        return try rlp.decode(allocator, Block, data);
    }

    // Hash returns the Keccak256 hash of the header
    pub fn hash(self: *const Block) Hash {
        var h_res = Hash.zero();
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});

        const ally = std.heap.page_allocator;
        const encoded = self.header.rlp_encode(ally) catch return h_res;
        defer ally.free(encoded);

        hasher.update(encoded);
        hasher.final(&h_res.bytes);
        return h_res;
    }

    pub fn deinit(self: Block, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        for (self.transactions) |tx| {
            tx.deinit(allocator);
        }
        allocator.free(self.transactions);
    }
};
