const std = @import("std");
const verkle = @import("verkle-crypto");
const banderwagon = verkle.banderwagon;
const Element = banderwagon.Element;

/// Verkle Node Types
pub const NodeType = enum(u8) {
    Internal = 0x01,
    Leaf = 0x02,
};

/// Internal Node: Commits to 256 children
pub const InternalNode = struct {
    children: [256]Element, // Current child commitments
    commitment: Element, // Self commitment

    pub fn init() InternalNode {
        return InternalNode{
            // Identity is 'zero' point, effectively empty
            .children = [_]Element{Element.identity()} ** 256,
            .commitment = Element.identity(),
        };
    }

    pub fn updateCommitment(self: *InternalNode, crs: verkle.crs.CRS) !void {
        var scalars: [256]banderwagon.Fr = undefined;
        for (self.children, 0..) |child, i| {
            // Map Point -> Scalar (Hash or Field conversion)
            // For now, we use bytes -> Fr. Ideally use a dedicated HashToField
            // to ensure uniform distribution if this is a random oracle behavior.
            var bytes = child.toBytes();
            // We interpret the 32 bytes of the compressed point as a scalar?
            // Or hash it? Standard Verkle hashes the commitment to field.
            // Let's assume Fr.fromLittleEndian or similar exists.
            // checking crs.zig... it uses Fr.fromInteger.
            // We'll use a placeholder conversion for now:
            const val = std.mem.readInt(u256, &bytes, .little);
            scalars[i] = banderwagon.Fr.fromInteger(val);
            // Note: fromInteger might reduce modulo r.
        }
        self.commitment = try crs.commit(&scalars);
    }

    // Serialization helper
    pub fn serialize(self: *const InternalNode, allocator: std.mem.Allocator) ![]const u8 {
        // [Type(1)] [Commitment(32)] [Children(256*32)]
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);
        try list.append(allocator, @intFromEnum(NodeType.Internal));
        try list.appendSlice(allocator, &self.commitment.toBytes());
        for (self.children) |child| {
            try list.appendSlice(allocator, &child.toBytes());
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Leaf Node: Stores specific value
pub const LeafNode = struct {
    key: [32]u8,
    value: []u8,
    commitment: Element,

    pub fn init(allocator: std.mem.Allocator, key: [32]u8, value: []const u8) !LeafNode {
        const val_copy = try allocator.dupe(u8, value);
        return LeafNode{
            .key = key,
            .value = val_copy,
            .commitment = Element.identity(),
        };
    }

    pub fn deinit(self: *LeafNode, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }

    // Serialization helper
    pub fn serialize(self: *const LeafNode, allocator: std.mem.Allocator) ![]const u8 {
        // [Type(1)] [Key(32)] [ValLen(4)] [Value...]
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);
        try list.append(allocator, @intFromEnum(NodeType.Leaf));
        try list.appendSlice(allocator, &self.key);
        try list.appendSlice(allocator, std.mem.asBytes(&@as(u32, @intCast(self.value.len))));
        try list.appendSlice(allocator, self.value);
        return list.toOwnedSlice(allocator);
    }
};

/// Extension Node: Represents the bottom layer (Stems), committing to 256 suffixes (Values)
pub const ExtensionNode = struct {
    stem: [31]u8,
    values: [256]?[32]u8, // Values are 32 bytes (or hash thereof)
    commitment: Element,

    pub fn init(stem: [31]u8) ExtensionNode {
        return ExtensionNode{
            .stem = stem,
            .values = [_]?[32]u8{null} ** 256,
            .commitment = Element.identity(),
        };
    }

    pub fn set(self: *ExtensionNode, suffix: u8, value: [32]u8) void {
        self.values[suffix] = value;
    }

    pub fn updateCommitment(self: *ExtensionNode, crs: verkle.crs.CRS) !void {
        var scalars: [256]banderwagon.Fr = undefined;
        for (self.values, 0..) |val_opt, i| {
            if (val_opt) |val| {
                scalars[i] = banderwagon.Fr.fromInteger(std.mem.readInt(u256, &val, .little));
            } else {
                scalars[i] = banderwagon.Fr.fromInteger(0);
            }
        }
        self.commitment = try crs.commit(&scalars);
    }

    pub fn serialize(self: *const ExtensionNode, allocator: std.mem.Allocator) ![]const u8 {
        // [Type(1)] [Stem(31)] [Commitment(32)] [Bitmap(32)] [Values...]
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        // Type 3 = Extension
        try list.append(allocator, 0x03);
        try list.appendSlice(allocator, &self.stem);
        try list.appendSlice(allocator, &self.commitment.toBytes());

        var bitmap = [_]u8{0} ** 32;
        for (self.values, 0..) |val, i| {
            if (val) |_| {
                const byte_idx = i / 8;
                const bit_idx = i % 8; // 0..7
                bitmap[byte_idx] |= (@as(u8, 1) << @truncate(bit_idx));
            }
        }
        try list.appendSlice(allocator, &bitmap);

        for (self.values) |val| {
            if (val) |v| {
                try list.appendSlice(allocator, &v);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn deserialize(data: []const u8) !ExtensionNode {
        // Min size: 1 + 31 + 32 + 32 = 96 bytes
        if (data.len < 96) return error.InvalidData;

        // Type check
        if (data[0] != 0x03) return error.InvalidNodeType;

        var stem: [31]u8 = undefined;
        @memcpy(&stem, data[1..32]);

        // Commitment
        // We need to parse bytes -> Element. Banderwagon Element.fromBytes?
        // Let's assume generic deserialization for now or Identity if lazy.
        // Usually we trust the commitment in DB or verify it?
        // For read, we just load it.
        var comm_bytes: [32]u8 = undefined;
        @memcpy(&comm_bytes, data[32..64]);
        const comm = try Element.fromBytes(comm_bytes);

        var node = ExtensionNode.init(stem);
        node.commitment = comm;

        const bitmap = data[64..96];
        var offset: usize = 96;

        for (0..256) |i| {
            const byte_idx = i / 8;
            const bit_idx = i % 8;
            const is_set = (bitmap[byte_idx] >> @truncate(bit_idx)) & 1 == 1;
            if (is_set) {
                if (offset + 32 > data.len) return error.InvalidData;
                var val: [32]u8 = undefined;
                @memcpy(&val, data[offset .. offset + 32]);
                node.values[i] = val;
                offset += 32;
            }
        }

        return node;
    }
};
