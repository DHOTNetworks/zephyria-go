const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("memtable.zig").MemTable;
const Wal = @import("wal.zig").WAL;
const io = @import("io.zig");

/// Simple LSM-based Key-Value Store
pub const DB = struct {
    allocator: Allocator,
    memtable: *MemTable,
    wal: *Wal,
    io_engine: io.IoEngine,
    data_dir: []const u8,

    pub fn init(allocator: Allocator, data_dir: []const u8) !*DB {
        const self = try allocator.create(DB);

        // Create data directory
        std.fs.cwd().makePath(data_dir) catch {};

        // Initialize IO Engine
        const io_engine = try io.create(allocator);

        // Initialize WAL
        const wal_path = try std.fmt.allocPrint(allocator, "{s}/log.wal", .{data_dir});
        defer allocator.free(wal_path);
        const wal = try Wal.init(allocator, io_engine, wal_path);

        // Initialize MemTable (will replay WAL)
        const memtable = try MemTable.init(allocator, wal);

        self.* = DB{
            .allocator = allocator,
            .memtable = memtable,
            .wal = wal,
            .io_engine = io_engine,
            .data_dir = data_dir,
        };

        return self;
    }

    pub fn deinit(self: *DB) void {
        self.memtable.deinit();
        self.wal.deinit();
        self.io_engine.deinit();
        self.allocator.destroy(self);
    }

    /// Hash a variable-length key to a fixed 32-byte key using Blake3
    pub fn hashKey(key_slice: []const u8) [32]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(key_slice);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    pub fn put(self: *DB, key_slice: []const u8, value: []const u8) !void {
        std.debug.print("DISK: DB.put() key_slice len={d}, value len={d}\n", .{ key_slice.len, value.len });
        const key = hashKey(key_slice);
        try self.memtable.put(key, key_slice, value);
    }

    pub fn get(self: *DB, key_slice: []const u8) ?[]const u8 {
        std.debug.print("DISK: DB.get() key_slice len={d}, first 4 bytes={x}\n", .{ key_slice.len, if (key_slice.len >= 4) std.mem.readInt(u32, key_slice[0..4], .big) else 0 });
        const key = hashKey(key_slice);
        return self.memtable.get(key);
    }

    pub fn delete(self: *DB, key_slice: []const u8) !void {
        const key = hashKey(key_slice);
        try self.memtable.delete(key, key_slice);
    }

    /// Trigger manual flush/compaction
    pub fn flush(self: *DB) !void {
        _ = self;
        // TODO: Implement SSTable flush
    }

    /// Get abstract database interface
    pub fn asAbstractDB(self: *DB) @import("../mod.zig").DB {
        return @import("../mod.zig").DB{
            .ptr = self,
            .writeFn = write,
            .readFn = read,
        };
    }

    /// Wrapper for storage interface
    pub fn write(self: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const db: *DB = @ptrCast(@alignCast(self));
        if (key.len == 0 or value.len == 0) {
            return error.InvalidKeyOrValue;
        } else {
            return db.put(key, value);
        }
    }

    pub fn read(self: *anyopaque, key: []const u8) ?[]const u8 {
        const db: *DB = @ptrCast(@alignCast(self));
        return db.get(key);
    }
};
