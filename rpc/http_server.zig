const std = @import("std");
const core = @import("core");
const p2p = @import("p2p");
const methods = @import("methods.zig");

const MAX_READ_BUFFER_SIZE = 64 * 1024; // 64KB
const MAX_REQUEST_BODY_SIZE = 5 * 1024 * 1024; // 5MB

pub const Context = struct {
    allocator: std.mem.Allocator,
    wait_group: std.Thread.WaitGroup,
    tcp: std.net.Server,
    read_buffer_size: usize,
    handler: methods.RpcHandler,
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        chain: *core.blockchain.Blockchain,
        pool: *core.tx_pool.TxPool,
        exec: *core.executor.Executor,
        state: *core.state.State,
    ) !Context {
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        const tcp_server = try addr.listen(.{
            .force_nonblocking = false,
            .reuse_address = true,
        });

        const handler = methods.RpcHandler.init(allocator, chain, pool, exec, state);

        return .{
            .allocator = allocator,
            .wait_group = .{},
            .tcp = tcp_server,
            .read_buffer_size = MAX_READ_BUFFER_SIZE,
            .handler = handler,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn set_p2p(self: *Context, p2p_server: *p2p.Server) void {
        self.handler.set_p2p(p2p_server);
    }

    pub fn deinit(self: *Context) void {
        self.running.store(false, .seq_cst);
        self.tcp.deinit();
    }

    pub fn start(self: *Context) !void {
        const thread = try std.Thread.spawn(.{}, serve_loop, .{self});
        thread.detach();
    }
};

fn serve_loop(ctx: *Context) void {
    std.debug.print("RPC Server listening on port {}\n", .{ctx.tcp.listen_address.getPort()});
    while (ctx.running.load(.seq_cst)) {
        const conn = ctx.tcp.accept() catch |err| {
            if (!ctx.running.load(.seq_cst)) break; // Shutdown
            std.debug.print("RPC Accept error: {}\n", .{err});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handle_connection, .{ ctx, conn }) catch |err| {
            std.debug.print("RPC Spawn error: {}\n", .{err});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handle_connection(ctx: *Context, conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    // Simple buffer for headers
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;

    // Read Loop for Keep-Alive (simple version: close after one request commonly, but loop allows basic reuse)
    while (true) {
        // Read headers
        // We read until \r\n\r\n
        var header_end: ?usize = null;

        while (header_end == null) {
            if (total_read >= buf.len) return; // Header too long
            const n = conn.stream.read(buf[total_read..]) catch return;
            if (n == 0) return; // EOF
            total_read += n;

            if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |idx| {
                header_end = idx;
            }
        }

        const end = header_end.?;
        const headers = buf[0..end];
        const body_start = end + 4;
        const remaining_body_in_buf = total_read - body_start;

        // Parse Content-Length
        var content_length: usize = 0;
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        _ = it.first(); // Skip status line (GET / HTTP/1.1) checking later if needed. Assumed POST.

        while (it.next()) |line| {
            // Case insensitive check? simplified
            if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "Content-Length:")) {
                const val_str = std.mem.trim(u8, line[15..], " ");
                content_length = std.fmt.parseInt(usize, val_str, 10) catch 0;
            }
        }

        if (content_length > MAX_REQUEST_BODY_SIZE) {
            _ = conn.stream.write("HTTP/1.1 413 Payload Too Large\r\n\r\n") catch {};
            return;
        }

        // Read Body
        const body = ctx.allocator.alloc(u8, content_length) catch return;
        defer ctx.allocator.free(body);

        // Copy existing
        if (remaining_body_in_buf > 0) {
            const avail = @min(remaining_body_in_buf, content_length);
            @memcpy(body[0..avail], buf[body_start .. body_start + avail]);

            // If we have excess in buf (pipelining), we'd need to shift it. Simplified: ignore pipelining for now.
        }

        // Read rest
        var body_read = remaining_body_in_buf;
        while (body_read < content_length) {
            const n = conn.stream.read(body[body_read..]) catch return;
            if (n == 0) break;
            body_read += n;
        }

        // Handle Request
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();

        handle_request_raw(ctx, arena.allocator(), conn, body) catch |err| {
            std.debug.print("RPC Handle Error: {}\n", .{err});
            return;
        };

        // Reset buffer for next request?
        // For simplicity, we just break (close connection) after one request for now.
        // Proper keep-alive requires managing buffer cursor carefully.
        break;
    }
}

fn handle_request_raw(ctx: *Context, allocator: std.mem.Allocator, conn: std.net.Server.Connection, body: []const u8) !void {
    // Parse JSON-RPC
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try respond_raw(conn, 200, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}");
        return;
    };
    // No explicit parsed.deinit() needed if it uses the request arena, but parseFromSlice might use its own allocations.
    // Actually if we pass the arena allocator, parsed.value will be in the arena.
    // deinit() on parsed would free the Arena-allocated stuff if it's the only things there,
    // but arena.deinit() will catch it anyway.
    // However, parseFromSlice allocates the 'Value' structure itself too.
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try respond_raw(conn, 200, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"},\"id\":null}");
        return;
    }

    const method = root.object.get("method");
    const id = root.object.get("id");
    const params = root.object.get("params");

    // Validate JSON-RPC 2.0
    if (root.object.get("jsonrpc")) |val| {
        if (val != .string or !std.mem.eql(u8, val.string, "2.0")) {
            try respond_raw(conn, 200, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"},\"id\":null}");
            return;
        }
    }

    if (method == null or method.? != .string) {
        try respond_raw(conn, 200, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"},\"id\":null}");
        return;
    }

    const result = ctx.handler.handle_request(allocator, method.?.string, params orelse .null) catch |err| {
        std.debug.print("Internal RPC Error for method '{s}': {}\n", .{ method.?.string, err });

        if (err == error.MethodNotFound) {
            try respond_raw(conn, 200, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":null}");
            return;
        }

        // We need to form generic error
        // Simplification: static error
        try respond_raw(conn, 200, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}");
        return;
    };

    var response_json = std.ArrayListUnmanaged(u8){};
    defer response_json.deinit(allocator);

    const writer = response_json.writer(allocator);
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| {
        try dumpJson(i, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"result\":");
    try dumpJson(result, writer);
    try writer.writeAll("}");

    try respond_raw(conn, 200, response_json.items);
}

fn dumpJson(val: std.json.Value, writer: anytype) !void {
    switch (val) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try std.fmt.format(writer, "{}", .{i}),
        .float => |f| try std.fmt.format(writer, "{}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| {
            try writer.writeByte('"');
            try writer.writeAll(s); // TODO: Escape properly if needed.
            try writer.writeByte('"');
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try dumpJson(item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeByte('"');
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeByte('"');
                try writer.writeByte(':');
                try dumpJson(entry.value_ptr.*, writer);
                i += 1;
            }
            try writer.writeByte('}');
        },
    }
}

fn respond_raw(conn: std.net.Server.Connection, status: usize, json_body: []const u8) !void {
    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {d}\r\n\r\n", .{ status, json_body.len });
    _ = try conn.stream.write(header);
    _ = try conn.stream.write(json_body);
}

fn respond_json_error_raw(conn: std.net.Server.Connection, id: ?std.json.Value, code: i32, msg: []const u8) !void {
    _ = conn;
    _ = id;
    _ = code;
    _ = msg;
    // Unused helper but kept for parity if needed
}
