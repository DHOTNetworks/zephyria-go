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
