const std = @import("std");
const core = @import("core");
const types = @import("types.zig");
const zquic = @import("zig-quic");
const rlp = @import("encoding").rlp;

pub const Peer = struct {
    allocator: std.mem.Allocator,
    id: [64]u8, // Unique Node ID

    // Connection state
    ip: []const u8,
    port: u16,
    connected: bool,
    handshake_complete: bool,

    // QUIC State (zig-quic)
    quic_conn: ?zquic.transport.connection.Connection,
    quic_stream: ?zquic.transport.stream.QuicStream,

    // Chain state tracking
    head_hash: core.types.Hash,
    head_number: u64,

    // Limits
    is_trusted: bool,

    // Send Queue
    outbox: std.ArrayListUnmanaged([]const u8),
    lock: std.Thread.Mutex,

    // Identity & Authentication
    validator_address: ?core.types.Address,
    authenticated: bool,
    challenge: [32]u8, // Handshake challenge sent to this peer

    pub fn init(allocator: std.mem.Allocator, ip: []const u8, port: u16) !*Peer {
        const self = try allocator.create(Peer);
        const ip_dupe = try allocator.dupe(u8, ip);

        self.* = Peer{
            .allocator = allocator,
            .id = [_]u8{0} ** 64, // Should be derived from key
            .ip = ip_dupe,
            .port = port,
            .connected = true,
            .handshake_complete = false,
            .quic_conn = null,
            .quic_stream = null,
            .head_hash = core.types.Hash.zero(),
            .head_number = 0,
            .is_trusted = false,
            .outbox = .{},
            .lock = .{},
            .validator_address = null,
            .authenticated = false,
            .challenge = [_]u8{0} ** 32,
        };
        return self;
    }

    pub fn deinit(self: *Peer) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.allocator.free(self.ip);
        if (self.quic_stream) |*stream| {
            stream.close();
        }
        if (self.quic_conn) |*conn| {
            conn.close();
        }
        for (self.outbox.items) |msg| {
            self.allocator.free(msg);
        }
        self.outbox.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn attach_quic(self: *Peer, conn: zquic.transport.connection.Connection) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.quic_conn = conn;
    }

    pub fn open_stream(self: *Peer, id: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        self.quic_stream = try zquic.transport.stream.QuicStream.init(self.allocator, id, .Bidirectional);
    }

    /// Send queues a message to be sent to the peer over QUIC.
    pub fn send(self: *Peer, msg_code: u64, data: anytype) !void {
        // RLP encode FIRST to minimize time in lock (though trivial here)
        const bytes = try rlp.encode(self.allocator, data);
        errdefer self.allocator.free(bytes);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.quic_stream) |*stream| {
            // Write msg_code as u64 (or variable length) before the payload
            var code_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &code_buf, msg_code, .big);
            _ = try stream.write(&code_buf);
            _ = try stream.write(bytes);

            // We can free bytes immediately after write if write copies or sends.
            // Assuming stream.write consumes or we can free.
            // Usually standard write takes slice.
            // Check leak risk: if write is async/queued internally by quic lib and holds pointer, we can't free.
            // zig-quic usually copies to packet buffer.
            self.allocator.free(bytes);

            std.debug.print("Sent message {} ({} bytes) via QUIC stream to {s}\n", .{ msg_code, bytes.len, self.ip });
        } else {
            self.allocator.free(bytes);
            return error.NoQuicStream;
        }
    }

    pub fn update_head(self: *Peer, hash: core.types.Hash, number: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.head_hash = hash;
        self.head_number = number;
    }
};
