const std = @import("std");
const core = @import("core");
const consensus = @import("consensus");
const types = @import("types.zig");
const Peer = @import("peer.zig").Peer;
const zquic = @import("zig-quic");
const posix = std.posix;
const Connection = zquic.transport.connection.Connection;
const rlp = @import("encoding").rlp;

// Optimizations
const Packet = @import("net_utils").Packet;
const socket_utils = @import("net_utils").socket_utils;
const allocators = @import("utils").allocators;
const SwissMap = @import("utils").SwissMap;

// We use a pointer to Packet for pooling to avoid copying large structs
const PacketPool = allocators.RecycleBuffer(Packet, Packet.ANY_EMPTY, .{});

// Helper for SwissMap (u64 key)
inline fn hashU64(key: u64) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
}
inline fn eqU64(a: u64, b: u64) bool {
    return a == b;
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    peers: std.ArrayListUnmanaged(*Peer),
    chain: *core.Blockchain,
    engine: *consensus.ZeliusEngine,

    // Config
    listen_addr: []const u8,
    listen_port: u16,

    // Networking
    sock: posix.socket_t,
    peers_by_id: SwissMap(u64, *Peer, hashU64, eqU64), // Optimized map

    running: bool,
    thread: ?std.Thread,
    pool: std.Thread.Pool,
    lock: std.Thread.Mutex,

    // New Optimizations
    packet_pool: *PacketPool,

    // Outbox for batching
    outbox: std.ArrayListUnmanaged(Packet),
    outbox_lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, chain: *core.Blockchain, engine: *consensus.ZeliusEngine, port: u16) !*Server {
        const self = try allocator.create(Server);

        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
        errdefer posix.close(sock);

        // Reuse addr
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Set Receive Timeout (100ms) to allow checking 'running' flag periodically
        const Timeval = extern struct {
            tv_sec: c_long,
            tv_usec: c_int,
        };
        const timeout = Timeval{ .tv_sec = 0, .tv_usec = 100 * 1000 };
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));

        const pool_ptr = try allocator.create(PacketPool);
        pool_ptr.* = PacketPool.init(.{
            .records_allocator = allocator,
            .memory_allocator = allocator,
        });
        try pool_ptr.expandCapacity(4096);

        self.* = Server{
            .allocator = allocator,
            .peers = .{},
            .chain = chain,
            .engine = engine,
            .listen_addr = "0.0.0.0",
            .listen_port = port,
            .sock = sock,
            .peers_by_id = SwissMap(u64, *Peer, hashU64, eqU64).init(allocator),
            .running = false,
            .thread = null,
            .pool = undefined,
            .lock = .{},
            .packet_pool = pool_ptr,
            .outbox = .{},
            .outbox_lock = .{},
        };

        // Initialize Thread Pool (4 workers)
        try self.pool.init(.{ .allocator = allocator, .n_jobs = 4 });

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.running = false;
        if (self.thread) |t| t.join();
        self.pool.deinit();

        posix.close(self.sock);

        for (self.peers.items) |peer| {
            peer.deinit();
        }
        self.peers.deinit(self.allocator);
        self.peers_by_id.deinit();

        self.packet_pool.deinit();
        self.allocator.destroy(self.packet_pool);

        self.outbox.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn start(self: *Server) !void {
        var addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.listen_port),
            .addr = 0, // 0.0.0.0
            .zero = [_]u8{0} ** 8,
        };

        try posix.bind(self.sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        std.debug.print("Initializing zig-quic P2P Server on port {} (Optimized Mode)...\n", .{self.listen_port});
        std.debug.print("Optimizations Enabled: RecycleBuffer, sendmmsg, SwissMap, WorkerPool\n", .{});

        self.running = true;
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    fn serverLoop(self: *Server) void {
        while (self.running) {
            // Optimization 1 & 2: RecycleBuffer + Zero Copy (mostly)
            const packets_slice = self.packet_pool.alloc(1) catch |err| {
                std.debug.print("Packet pool exhausted: {}\n", .{err});
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            var packet = &packets_slice[0];

            var from: posix.sockaddr.in = undefined;
            var fromlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);

            const len = posix.recvfrom(self.sock, &packet.buffer, 0, @ptrCast(&from), &fromlen) catch |err| {
                self.packet_pool.free(packets_slice.ptr);
                if (err == error.WouldBlock or err == error.Again) {
                    continue; // Timeout, loop back to check 'running'
                }
                std.debug.print("P2P Server recvfrom error: {}\n", .{err});
                continue;
            };

            packet.size = len;
            packet.addr = std.net.Address{ .in = @bitCast(from) };

            self.pool.spawn(handle_packet_wrapper, .{ self, packet, packets_slice.ptr }) catch {
                std.debug.print("P2P Server Pool full\n", .{});
                self.packet_pool.free(packets_slice.ptr);
            };

            self.flushOutbox() catch {};
        }
    }

    fn handle_packet_wrapper(self: *Server, packet: *Packet, ptr: [*]Packet) void {
        defer self.packet_pool.free(ptr);
        var from_addr = packet.addr.in;
        self.handle_packet(@ptrCast(&from_addr), packet.data()) catch |err| {
            if (err != error.EndOfStream) {
                std.debug.print("Error handling packet async: {}\n", .{err});
            }
        };
    }

    fn handle_packet(self: *Server, sender: *const posix.sockaddr.in, data: []const u8) !void {
        const decoded = try zquic.transport.packet.Packet.decode(data);
        const conn_id = decoded.connection_id;

        const peer = blk: {
            self.lock.lock();
            defer self.lock.unlock();

            if (self.peers_by_id.get(conn_id)) |p| {
                break :blk p;
            } else {
                var ip_buf: [20]u8 = undefined;
                const ip = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
                    (sender.addr >> 0) & 0xFF,
                    (sender.addr >> 8) & 0xFF,
                    (sender.addr >> 16) & 0xFF,
                    (sender.addr >> 24) & 0xFF,
                });
                const p = try Peer.init(self.allocator, ip, std.mem.bigToNative(u16, sender.port));

                var conn = try Connection.init(self.allocator);
                conn.connection_id = conn_id;
                try conn.establish();
                p.attach_quic(conn);
                try p.open_stream(1);

                // Send Status with challenge
                var challenge: [32]u8 = undefined;
                std.crypto.random.bytes(&challenge);
                p.challenge = challenge;

                const status = types.StatusMsg{
                    .chain_id = self.chain.chain_id,
                    .genesis_hash = self.chain.genesis_hash,
                    .head_hash = self.chain.get_head_hash(),
                    .head_number = self.chain.get_head_number(),
                    .challenge = challenge,
                };
                try p.send(types.MsgStatus, status);

                try self.peers.append(self.allocator, p);
                try self.peers_by_id.ensureTotalCapacity(self.peers_by_id.count() + 1);
                self.peers_by_id.putAssumeCapacity(conn_id, p);

                std.debug.print("New QUIC Peer connected: {s}:{}\n", .{ ip, p.port });
                break :blk p;
            }
        };

        if (decoded.payload.len >= 8) {
            const code = std.mem.readInt(u64, decoded.payload[0..8], .big);
            try self.handle_message(peer, code, decoded.payload[8..]);
        }
    }

    pub fn enqueue_send(self: *Server, dest: std.net.Address, data: []const u8) !void {
        self.outbox_lock.lock();
        defer self.outbox_lock.unlock();

        var pkt = Packet.init(dest, undefined, data.len);
        @memcpy(pkt.dataMut(), data);

        try self.outbox.append(self.allocator, pkt);

        if (self.outbox.items.len >= socket_utils.PACKETS_PER_BATCH) {
            try self.flushOutboxLocked();
        }
    }

    fn flushOutbox(self: *Server) !void {
        self.outbox_lock.lock();
        defer self.outbox_lock.unlock();
        try self.flushOutboxLocked();
    }

    fn flushOutboxLocked(self: *Server) !void {
        if (self.outbox.items.len == 0) return;

        const sent = try socket_utils.sendBatch(self.sock, self.outbox.items);

        if (sent > 0) {
            const remaining = self.outbox.items.len - sent;
            std.mem.copyForwards(Packet, self.outbox.items[0..remaining], self.outbox.items[sent..]);
            self.outbox.items.len = remaining;
        }
    }

    pub fn broadcast(self: *Server, msg_code: u64, msg: anytype) !void {
        self.lock.lock();
        const peers_slice = try self.allocator.dupe(*Peer, self.peers.items);
        self.lock.unlock();
        defer self.allocator.free(peers_slice);

        std.debug.print("Broadcasting message code {} to {} peers\n", .{ msg_code, peers_slice.len });
        for (peers_slice) |peer| {
            if (peer.handshake_complete) {
                try peer.send(msg_code, msg);
            }
        }
    }

    pub fn broadcast_subset(self: *Server, msg_code: u64, msg: anytype, fanout: usize, exclude: ?*Peer) !void {
        self.lock.lock();
        const all_peers = try self.allocator.dupe(*Peer, self.peers.items);
        self.lock.unlock();
        defer self.allocator.free(all_peers);

        var count: usize = 0;
        for (all_peers) |peer| {
            if (peer == exclude) continue;
            if (peer.handshake_complete) {
                try peer.send(msg_code, msg);
                count += 1;
                if (count >= fanout) break;
            }
        }
    }

    pub fn handle_message(self: *Server, peer: *Peer, code: u64, payload: []const u8) !void {
        switch (code) {
            types.MsgStatus => {
                const msg = try rlp.decode(self.allocator, types.StatusMsg, payload);
                try self.handle_status(peer, msg);
            },
            types.MsgNewBlock => {
                const msg = try rlp.decode(self.allocator, types.NewBlockMsg, payload);
                try self.handle_new_block(peer, msg);
            },
            types.MsgTx => {
                const msg = try rlp.decode(self.allocator, types.TxMsg, payload);
                try self.handle_tx(peer, msg);
            },
            types.MsgAuth => {
                const msg = try rlp.decode(self.allocator, types.AuthMsg, payload);
                try self.handle_auth(peer, msg);
            },
            else => {
                std.debug.print("Unknown P2P Message: {}\n", .{code});
            },
        }
    }

    fn handle_new_block(self: *Server, peer: *Peer, msg: types.NewBlockMsg) !void {
        std.debug.print("Received NewBlock: #{d} (hop: {d})\n", .{ msg.block.header.number, msg.hop_count });

        // TODO: Validate and add to chain
        // try self.chain.add_block(&msg.block);
        // Note: msg.block is owned by the decode allocator, need to check lifecycle.

        if (msg.hop_count < 2) {
            var relay_msg = msg;
            relay_msg.hop_count += 1;
            // Broadcast to a subset of peers (Fanout = 2)
            try self.broadcast_subset(types.MsgNewBlock, relay_msg, 2, peer);
        }
    }

    fn handle_auth(self: *Server, peer: *Peer, msg: types.AuthMsg) !void {
        _ = self;
        if (msg.signature.len != 64 or msg.public_key.len != 65) return error.InvalidAuth;

        var sig_bytes: [64]u8 = undefined;
        @memcpy(&sig_bytes, msg.signature[0..64]);

        var pub_key_bytes: [65]u8 = undefined;
        @memcpy(&pub_key_bytes, msg.public_key[0..65]);

        const valid = try core.account.verify_signature(peer.challenge, sig_bytes, pub_key_bytes);
        if (!valid) return error.AuthFailed;

        const addr = try core.account.addressFromPubKey(&pub_key_bytes);
        peer.lock.lock();
        defer peer.lock.unlock();
        peer.validator_address = addr;
        peer.authenticated = true;
        std.debug.print("Peer Authenticated: {s} as {f}\n", .{ peer.ip, addr });
    }

    fn handle_tx(self: *Server, peer: *Peer, msg: types.TxMsg) !void {
        _ = peer;
        // Gulf Stream: Forward to next leader if not us
        const current_number = self.chain.get_head_number();
        const next_leader = self.engine.get_leader(current_number + 1) orelse {
            // No leader schedule, just process locally (gossip)
            return;
        };

        // If we are the leader, do nothing (it's already in our pool if we are following standard flow?)
        // Actually, many nodes receive the same Tx.
        // For now, if we are NOT the leader, forward it once.

        // TODO: More sophisticated logic to avoid loops
        _ = next_leader;
        std.debug.print("Received Tx: from {any}\n", .{msg.tx.from});
    }

    fn handle_status(self: *Server, peer: *Peer, msg: types.StatusMsg) !void {
        _ = self;
        peer.update_head(msg.head_hash, msg.head_number);
        peer.lock.lock();
        defer peer.lock.unlock();
        peer.handshake_complete = true;
        std.debug.print("Peer Handshake Complete (QUIC): {s}\n", .{peer.ip});
    }
};
