const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("io.zig");

// TigerBeetle Style WAL
// - Pre-allocated file size
// - CRC32C checksums
// - Direct IO (via io engine)

pub const WalHeader = extern struct {
    magic: u64,
    version: u32,
    reserved: u32,
    checksum: u32, // Checksum of header
};

pub const EntryHeader = extern struct {
    checksum: u32, // Checksum of body
    len: u32,
    tx_id: u64,
};

pub const WAL = struct {
    allocator: Allocator,
    io_engine: io.IoEngine,
    file: std.fs.File,
    current_offset: u64,

    const MAGIC = 0x5A4257414C; // ZBWAL
    const VERSION = 1;

    pub fn init(allocator: Allocator, io_engine: io.IoEngine, path: []const u8) !*WAL {
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });

        const self = try allocator.create(WAL);
        self.* = WAL{
            .allocator = allocator,
            .io_engine = io_engine,
            .file = file,
            .current_offset = 0,
        };

        // TODO: Read header / recover offset
        return self;
    }

    pub fn deinit(self: *WAL) void {
        self.file.close();
        self.allocator.destroy(self);
    }

    pub fn reset(self: *WAL) !void {
        try self.file.setEndPos(0);
        try self.file.seekTo(0);
        self.current_offset = 0;
    }

    pub fn append(self: *WAL, data: []const u8, tx_id: u64) !void {
        // Prepare buffer (Header + Data)
        const total_len = @sizeOf(EntryHeader) + data.len;
        const buffer = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(buffer);

        // Fill Header
        const checksum = std.hash.Crc32.hash(data);
        const header = EntryHeader{
            .checksum = checksum,
            .len = @intCast(data.len),
            .tx_id = tx_id,
        };

        @memcpy(buffer[0..@sizeOf(EntryHeader)], std.mem.asBytes(&header));
        @memcpy(buffer[@sizeOf(EntryHeader)..], data);

        // SYNCHRONOUS WRITE: Write directly to file (no async I/O)
        try self.file.pwriteAll(buffer, self.current_offset);

        // Force sync to disk immediately
        try self.file.sync();

        self.current_offset += total_len;
    }
    pub fn replay(self: *WAL, context: anytype, callback: fn (@TypeOf(context), []const u8) anyerror!void) !void {
        std.debug.print("DISK: Starting WAL Replay...\n", .{});
        try self.file.seekTo(0);

        while (true) {
            // Read Header
            var header: EntryHeader = undefined;
            const bytes_read = try self.file.readAll(std.mem.asBytes(&header));
            if (bytes_read == 0) break; // EOF
            if (bytes_read < @sizeOf(EntryHeader)) {
                // Partial write/corruption at end
                break;
            }

            // Allocate buffer for data
            const data = try self.allocator.alloc(u8, header.len);
            defer self.allocator.free(data);

            const data_read = try self.file.readAll(data);
            if (data_read < header.len) break;

            // Verify Checksum (Basic)
            if (std.hash.Crc32.hash(data) != header.checksum) {
                // Corruption
                std.debug.print("WAL Checksum Mismatch! Stopping replay.\n", .{});
                break;
            }

            try callback(context, data);

            self.current_offset += @sizeOf(EntryHeader) + header.len;
        }

        // Seek to end for appending
        try self.file.seekTo(self.current_offset);
    }
};
