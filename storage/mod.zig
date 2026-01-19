pub const DB = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8) anyerror!void,
    readFn: *const fn (ptr: *anyopaque, key: []const u8) ?[]const u8,

    pub fn write(self: DB, key: []const u8, value: []const u8) !void {
        return self.writeFn(self.ptr, key, value);
    }

    pub fn read(self: DB, key: []const u8) ?[]const u8 {
        return self.readFn(self.ptr, key);
    }
};

pub const lsm = struct {
    pub const io = @import("lsm/io.zig");
    pub const db = @import("lsm/db.zig");
    pub const wal = @import("lsm/wal.zig");
    pub const memtable = @import("lsm/memtable.zig");
};

pub const verkle = struct {
    pub const node = @import("verkle/node.zig");
    pub const trie = @import("verkle/trie.zig");
};

pub const state = @import("state.zig");

test {
    // Include sub-module tests
    _ = @import("lsm/test_memtable_leaks.zig");
    _ = @import("lsm/tests/test_flush.zig");
    _ = @import("lsm/tests/test_sstable_features.zig");
    _ = verkle.trie;
}

// Original Generic Storage Stub (to be deprecated/wrapped)
const std = @import("std");
pub const Storage = struct {
    map: std.AutoHashMap([32]u8, [32]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Storage {
        var s = try allocator.create(Storage);
        s.map = std.AutoHashMap([32]u8, [32]u8).init(allocator);
        s.allocator = allocator;
        return s;
    }

    pub fn deinit(self: *Storage) void {
        self.map.deinit();
        self.allocator.destroy(self);
    }
};
