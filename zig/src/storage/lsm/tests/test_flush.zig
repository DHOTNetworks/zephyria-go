const std = @import("std");
const DB = @import("../db.zig").DB;

test "LSM manual flush and persistence" {
    const allocator = std.testing.allocator;
    const test_dir = "test-lsm-flush";

    // Cleanup before
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Phase 1: Write and Flush
    {
        var db = try DB.init(allocator, test_dir);
        defer db.deinit();

        // 1. Write Data
        try db.put("key1", "val1");
        try db.put("key2", "val2");

        // 2. Flush (Should create 0.sst)
        try db.flush();

        // 3. Write more data (MemTable + WAL)
        try db.put("key3", "val3");

        // Verify "key1" is readable (from SSTable)
        const v1 = db.get("key1");
        try std.testing.expect(v1 != null);
        try std.testing.expectEqualStrings("val1", v1.?);
    }

    // Phase 2: Restart (Verify Persistence)
    {
        var db = try DB.init(allocator, test_dir);
        defer db.deinit();

        // Check SSTable data (should be loaded from 0.sst)
        const v1 = db.get("key1");
        try std.testing.expect(v1 != null);
        try std.testing.expectEqualStrings("val1", v1.?);

        const v2 = db.get("key2");
        try std.testing.expect(v2 != null);
        try std.testing.expectEqualStrings("val2", v2.?);

        // Check WAL/MemTable recovered data (key3 was not flushed, so in WAL)
        const v3 = db.get("key3");
        try std.testing.expect(v3 != null);
        try std.testing.expectEqualStrings("val3", v3.?);
    }
}
