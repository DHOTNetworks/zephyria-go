const std = @import("std");
const MemTable = @import("memtable.zig").MemTable;
const Wal = @import("wal.zig").WAL;
const io = @import("io.zig");

test "MemTable Memory Leak Check" {
    const allocator = std.testing.allocator;

    // Setup Mock/Temp WAL
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // We need WAL init.. assuming we can mock it or use real one
    // IoEngine mockup or real...
    const io_engine = try io.create(allocator);
    defer io_engine.deinit();

    const wal_path = try std.fmt.allocPrint(allocator, "test_memtable.wal", .{});
    defer allocator.free(wal_path);

    // This creates real file in CWD, better to control path
    // For specific test assume `lsm/wal.zig` works
    const wal = try Wal.init(allocator, io_engine, wal_path);

    var memtable = try MemTable.init(allocator, wal);

    // Perform operations
    const key = [_]u8{0} ** 32; // Fixed: const
    const value = "value_data";
    try memtable.put(key, "orig_key", value);

    // Deinit
    memtable.deinit();
    wal.deinit();

    std.fs.cwd().deleteFile("test_memtable.wal") catch {};
}
