const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bloom Filter Implementation
const BloomFilter = struct {
    bits: []u8,
    k: usize, // number of hash functions
    allocator: Allocator,

    pub fn init(allocator: Allocator, expected_elements: usize, false_positive_rate: f64) !BloomFilter {
        const n = @as(f64, @floatFromInt(expected_elements));
        // m = -n*ln(p) / (ln(2)^2)
        const m_f = -n * @log(false_positive_rate) / (@log(2.0) * @log(2.0));
        var m: usize = @intFromFloat(@ceil(m_f));
        // Ensure byte alignment
        m = (m + 7) / 8 * 8;

        // k = (m/n) * ln(2)
        const k_f = (m_f / n) * @log(2.0);
        const k: usize = @as(usize, @intFromFloat(@ceil(k_f)));

        const bits = try allocator.alloc(u8, m / 8);
        @memset(bits, 0);

        return BloomFilter{
            .bits = bits,
            .k = if (k < 1) 1 else k,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bits);
    }

    pub fn add(self: *BloomFilter, key: [32]u8) void {
        // Use the key itself (already hashed) as entropy
        const h1 = std.mem.readInt(u64, key[0..8], .little);
        const h2 = std.mem.readInt(u64, key[8..16], .little);
        const bit_len = self.bits.len * 8;

        for (0..self.k) |i| {
            const idx = (h1 +% (@as(u64, i) *% h2)) % bit_len;
            const byte_idx = idx / 8;
            const bit_idx = @as(u3, @intCast(idx % 8));
            self.bits[byte_idx] |= @as(u8, 1) << bit_idx;
        }
    }

    pub fn contains(self: *const BloomFilter, key: [32]u8) bool {
        const h1 = std.mem.readInt(u64, key[0..8], .little);
        const h2 = std.mem.readInt(u64, key[8..16], .little);
        const bit_len = self.bits.len * 8;

        for (0..self.k) |i| {
            const idx = (h1 +% (@as(u64, i) *% h2)) % bit_len;
            const byte_idx = idx / 8;
            const bit_idx = @as(u3, @intCast(idx % 8));
            if ((self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) return false;
        }
        return true;
    }
};

/// Enhanced SSTable Builder
/// Format:
/// [Magic: 4 bytes ("ZST1")]
/// [Count: u32]
/// [BloomFilterOffset: u64]
/// [IndexOffset: u64]
/// [DataOffset: u64]
/// [Bloom Filter Data: Len(4) + Bits...]
/// [Index: Key(32) + Offset(8) ...]
/// [Data: Checksum(4) + Key(32) + ValLen(4) + Value ...]
pub const SSTableBuilder = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(Entry),

    pub const Entry = struct {
        key: [32]u8,
        value: []const u8,
    };

    pub fn init(allocator: Allocator) SSTableBuilder {
        return SSTableBuilder{
            .allocator = allocator,
            .entries = .{},
        };
    }

    pub fn deinit(self: *SSTableBuilder) void {
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *SSTableBuilder, key: [32]u8, value: []const u8) !void {
        try self.entries.append(self.allocator, Entry{ .key = key, .value = value });
    }

    fn sort(self: *SSTableBuilder) void {
        std.sort.block(Entry, self.entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, &a.key, &b.key) == .lt;
            }
        }.less);
    }

    fn writeInt(file: std.fs.File, comptime T: type, val: T) !void {
        var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buf, val, .little);
        try file.writeAll(&buf);
    }

    pub fn finish(self: *SSTableBuilder, path: []const u8) !void {
        self.sort();

        // 1. Prepare Bloom Filter
        var bloom = try BloomFilter.init(self.allocator, self.entries.items.len, 0.01);
        defer bloom.deinit();

        for (self.entries.items) |entry| {
            bloom.add(entry.key);
        }

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Header: [Magic(4)][Count(4)][BloomOff(8)][IndexOff(8)][DataOff(8)]
        // Total Header size: 4 + 4 + 8 + 8 + 8 = 32 bytes
        try file.writeAll("ZST1");
        try writeInt(file, u32, @intCast(self.entries.items.len));

        // Placeholder offsets
        try writeInt(file, u64, 0);
        try writeInt(file, u64, 0);
        try writeInt(file, u64, 0);

        const bloom_offset = try file.getPos();

        // Write Bloom Filter: [K(4)][Len(4)][Bits...]
        try writeInt(file, u32, @intCast(bloom.k));
        try writeInt(file, u32, @intCast(bloom.bits.len));
        try file.writeAll(bloom.bits);

        const index_offset = try file.getPos();

        // Calculate Data Offsets for Index
        var current_data_offset: u64 = 0; // Relative to Data Start
        // But we need absolute offset? No, let's use absolute.
        // We don't know data start yet.
        // Actually, we can calculate it: Index size = count * 40.
        // Data start = index_offset + (count * 40)
        const data_start_offset = index_offset + (@as(u64, self.entries.items.len) * 40);

        // Write Index
        current_data_offset = data_start_offset;
        for (self.entries.items) |entry| {
            try file.writeAll(&entry.key);
            try writeInt(file, u64, current_data_offset);

            // Data Entry: [Checksum(4)][Key(32)][ValLen(4)][Value]
            current_data_offset += 4 + 32 + 4 + entry.value.len;
        }

        const data_offset_recorded = try file.getPos();
        std.debug.assert(data_offset_recorded == data_start_offset);

        // Write Data
        for (self.entries.items) |entry| {
            // Calculate Checksum (CRC32C) of Key + ValLen + Value
            var crc = std.hash.Crc32.init();
            crc.update(&entry.key);

            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(entry.value.len), .little);
            crc.update(&len_buf);

            crc.update(entry.value);
            const checksum = crc.final();

            try writeInt(file, u32, checksum);
            try file.writeAll(&entry.key); // Redundant key for integrity? Yes, standard practice.
            try file.writeAll(&len_buf);
            try file.writeAll(entry.value);
        }

        // Backpatch Offsets
        try file.seekTo(8);
        try writeInt(file, u64, bloom_offset);
        try writeInt(file, u64, index_offset);
        try writeInt(file, u64, data_start_offset);
    }
};

/// Enhanced Reader
pub const SSTableReader = struct {
    allocator: Allocator,
    file: std.fs.File,
    data: []const u8,
    count: u32,
    bloom_filter: BloomFilter,
    index_offset: u64,
    data_offset: u64,

    pub fn init(allocator: Allocator, path: []const u8) !SSTableReader {
        const file = try std.fs.cwd().openFile(path, .{});
        const stat = try file.stat();
        const data = try file.readToEndAlloc(allocator, stat.size);

        if (data.len < 32) return error.InvalidSSTable;
        if (!std.mem.eql(u8, data[0..4], "ZST1")) return error.InvalidFormat;

        const count = std.mem.readInt(u32, data[4..8], .little);
        const bloom_off = std.mem.readInt(u64, data[8..16], .little);
        const index_off = std.mem.readInt(u64, data[16..24], .little);
        const data_off = std.mem.readInt(u64, data[24..32], .little);

        if (bloom_off >= data.len or index_off >= data.len or data_off >= data.len) return error.CorruptHeader;

        // Load Bloom Filter
        // [K(4)][Len(4)][Bits...]
        if (bloom_off + 8 > data.len) return error.CorruptBloomFilter;
        const k = std.mem.readInt(u32, data[bloom_off..][0..4], .little);
        const bits_len = std.mem.readInt(u32, data[bloom_off + 4 ..][0..4], .little);

        if (bloom_off + 8 + bits_len > data.len) return error.CorruptBloomFilter;

        // We copy bits to own them in struct, or just ref?
        // Struct expects own slice usually if we want to reuse logic.
        // But here we are mmap/buffer based. Let's adapt BloomFilter to use slice ref if possible,
        // OR duplicate. Duplicating is safer for ownership if we deinit reader.
        const bits = try allocator.dupe(u8, data[bloom_off + 8 .. bloom_off + 8 + bits_len]);

        return SSTableReader{
            .allocator = allocator,
            .file = file,
            .data = data,
            .count = count,
            .bloom_filter = BloomFilter{
                .bits = bits,
                .k = k,
                .allocator = allocator,
            },
            .index_offset = index_off,
            .data_offset = data_off,
        };
    }

    pub fn deinit(self: *SSTableReader) void {
        self.bloom_filter.deinit();
        self.allocator.free(self.data);
        self.file.close();
    }

    pub fn get(self: *SSTableReader, key: [32]u8) ?[]const u8 {
        // 1. Check Bloom Filter
        if (!self.bloom_filter.contains(key)) return null;

        // 2. Binary Search Index
        var left: usize = 0;
        var right: usize = self.count;
        const idx_start = self.index_offset;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const idx_entry = idx_start + (mid * 40);

            if (idx_entry + 40 > self.data_offset) break;

            const mid_key = self.data[idx_entry .. idx_entry + 32];

            switch (std.mem.order(u8, mid_key, &key)) {
                .eq => {
                    const offset = std.mem.readInt(u64, self.data[idx_entry + 32 ..][0..8], .little);
                    if (offset >= self.data.len) return null;

                    // Read Data Entry: [Checksum(4)][Key(32)][ValLen(4)][Value]
                    if (offset + 4 + 32 + 4 > self.data.len) return null;

                    const stored_checksum = std.mem.readInt(u32, self.data[offset..][0..4], .little);
                    const stored_key = self.data[offset + 4 ..][0..32];
                    const val_len = std.mem.readInt(u32, self.data[offset + 36 ..][0..4], .little);

                    if (offset + 40 + val_len > self.data.len) return null;
                    const val = self.data[offset + 40 .. offset + 40 + val_len];

                    // Verify Key (redundant sanity check)
                    if (!std.mem.eql(u8, stored_key, &key)) return null; // Should not happen with index match

                    // Verify Checksum
                    var crc = std.hash.Crc32.init();
                    crc.update(stored_key);
                    var len_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &len_buf, val_len, .little);
                    crc.update(&len_buf);
                    crc.update(val);

                    if (crc.final() != stored_checksum) {
                        std.debug.print("Checksum mismatch for key!\n", .{});
                        return null; // or error
                    }

                    return val;
                },
                .lt => left = mid + 1,
                .gt => right = mid,
            }
        }
        return null;
    }
};
