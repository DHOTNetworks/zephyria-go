const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("memtable.zig").MemTable;
const Wal = @import("wal.zig").WAL;
const io = @import("io.zig");
const sstable = @import("sstable.zig");
const SSTableBuilder = sstable.SSTableBuilder;
const SSTableReader = sstable.SSTableReader;

// Use Unmanaged to avoid init issues
const SSTList = std.ArrayListUnmanaged(SSTableReader);

/// Simple LSM-based Key-Value Store
pub const DB = struct {
    allocator: Allocator,
    memtable: *MemTable,
    wal: *Wal,
    io_engine: io.IoEngine,
    data_dir: []const u8,
    sstables: SSTList,
    next_sst_id: u64,

    pub fn init(allocator: Allocator, data_dir: []const u8) !*DB {
        const self = try allocator.create(DB);

        std.fs.cwd().makePath(data_dir) catch {};

        const io_engine = try io.create(allocator);

        const wal_path = try std.fmt.allocPrint(allocator, "{s}/log.wal", .{data_dir});
        defer allocator.free(wal_path);
        const wal = try Wal.init(allocator, io_engine, wal_path);

        const memtable = try MemTable.init(allocator, wal);

        self.* = DB{
            .allocator = allocator,
            .memtable = memtable,
            .wal = wal,
            .io_engine = io_engine,
            .data_dir = data_dir,
            .sstables = .{}, // Unmanaged init
            .next_sst_id = 0,
        };

        try self.loadSSTables();

        return self;
    }

    pub fn deinit(self: *DB) void {
        for (self.sstables.items) |*sst| {
            sst.deinit();
        }
        self.sstables.deinit(self.allocator);
        self.memtable.deinit();
        self.wal.deinit();
        self.io_engine.deinit();
        self.allocator.destroy(self);
    }

    fn loadSSTables(self: *DB) !void {
        var id: u64 = 0;
        while (true) : (id += 1) {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{d}.sst", .{ self.data_dir, id });
            defer self.allocator.free(path);

            if (SSTableReader.init(self.allocator, path)) |sst| {
                try self.sstables.append(self.allocator, sst);
                self.next_sst_id = id + 1;
            } else |_| {
                break;
            }
        }
    }

    pub fn hashKey(key_slice: []const u8) [32]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(key_slice);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    pub fn put(self: *DB, key_slice: []const u8, value: []const u8) !void {
        const key = hashKey(key_slice);
        try self.memtable.put(key, key_slice, value);
        if (self.memtable.size_bytes > 64 * 1024 * 1024) {
            try self.flush();
        }
    }

    pub fn get(self: *DB, key_slice: []const u8) ?[]const u8 {
        const key = hashKey(key_slice);
        if (self.memtable.get(key)) |val| {
            return val;
        }

        var i = self.sstables.items.len;
        while (i > 0) {
            i -= 1;
            const sst = &self.sstables.items[i];
            if (sst.get(key)) |val| {
                return val;
            }
        }
        return null;
    }

    pub fn delete(self: *DB, key_slice: []const u8) !void {
        const key = hashKey(key_slice);
        try self.memtable.delete(key, key_slice);
    }

    pub fn flush(self: *DB) !void {
        if (self.memtable.table.count() == 0) return;

        var builder = SSTableBuilder.init(self.allocator);
        defer builder.deinit();

        var it = self.memtable.table.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.value) |v| {
                try builder.add(entry.key_ptr.*, v);
            }
        }

        const filename = try std.fmt.allocPrint(self.allocator, "{s}/{d}.sst", .{ self.data_dir, self.next_sst_id });
        defer self.allocator.free(filename);

        try builder.finish(filename);

        const reader = try SSTableReader.init(self.allocator, filename);
        try self.sstables.append(self.allocator, reader);
        self.next_sst_id += 1;

        var val_it = self.memtable.table.valueIterator();
        while (val_it.next()) |v| {
            if (v.value) |bytes| self.allocator.free(bytes);
        }
        self.memtable.table.clearRetainingCapacity();
        self.memtable.size_bytes = 0;

        try self.wal.reset();
    }

    pub fn asAbstractDB(self: *DB) @import("../mod.zig").DB {
        return @import("../mod.zig").DB{
            .ptr = self,
            .writeFn = write,
            .readFn = read,
        };
    }

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
