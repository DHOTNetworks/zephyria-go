const std = @import("std");
const sstable = @import("../sstable.zig");
const SSTableBuilder = sstable.SSTableBuilder;
const SSTableReader = sstable.SSTableReader;
const Allocator = std.mem.Allocator;

test "SSTable Bloom Filter and Checksums" {
    const allocator = std.testing.allocator;
    const test_file = "test_features.sst";

    defer std.fs.cwd().deleteFile(test_file) catch {};

    const key1 = [_]u8{1} ** 32;
    const val1 = "value1";
    const key2 = [_]u8{2} ** 32;
    const val2 = "value2";

    // 1. Build SSTable
    {
        var builder = SSTableBuilder.init(allocator);
        defer builder.deinit();

        try builder.add(key1, val1);
        try builder.add(key2, val2);
        try builder.finish(test_file);
    }

    // 2. Read and Verify Features
    {
        var reader = try SSTableReader.init(allocator, test_file);
        defer reader.deinit();

        // Positive Lookup
        if (reader.get(key1)) |v| {
            try std.testing.expectEqualStrings(val1, v);
        } else return error.Key1NotFound;

        if (reader.get(key2)) |v| {
            try std.testing.expectEqualStrings(val2, v);
        } else return error.Key2NotFound;

        // Negative Lookup (Bloom Filter)
        const key3 = [_]u8{3} ** 32;
        // Verify key3 is NOT in sstable
        try std.testing.expect(reader.get(key3) == null);

        // Access internal bloom filter to verify it checks out
        try std.testing.expect(reader.bloom_filter.contains(key1));
        try std.testing.expect(reader.bloom_filter.contains(key2));
        try std.testing.expect(!reader.bloom_filter.contains(key3)); // High probability true
    }

    // 3. Corrupt Data (Test Checksum)
    // We strictly assume format: Header(32) + Bloom + Index + Data
    // We will corrupt the last byte of the file (likely part of value2 or its checksum/len)
    // Actually, let's find where val1 is and corrupt it.
    {
        const file = try std.fs.cwd().openFile(test_file, .{ .mode = .read_write });
        defer file.close();
        const stat = try file.stat();
        const data = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(data);

        // Find "value1" in data and flip a bit
        if (std.mem.indexOf(u8, data, "value1")) |idx| {
            // Modify file at that offset
            try file.seekTo(idx);
            try file.writeAll(&[_]u8{data[idx] ^ 0xFF});
        } else return error.Value1NotFoundInFile;
    }

    // 4. Verify Checksum Failure
    {
        var reader = try SSTableReader.init(allocator, test_file);
        defer reader.deinit();

        // Lookup key1 should fail due to checksum mismatch
        // Our implementation prints "Checksum mismatch" and returns null.
        if (reader.get(key1)) |_| {
            return error.ChecksumFailedToCatchCorruption;
        }

        // Key2 should still be fine (unless we corrupted shared block, but separate entries)
        if (reader.get(key2)) |v| {
            try std.testing.expectEqualStrings(val2, v);
        } else return error.Key2AffectedByCorruption;
    }
}
