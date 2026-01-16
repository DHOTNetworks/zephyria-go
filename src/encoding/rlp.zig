const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidInput,
    TooLarge,
    UnexpectedEnd,
    Overflow,
};

/// Encodes an object to RLP bytes.
pub fn encode(allocator: Allocator, value: anytype) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try encodeToWriter(allocator, out.writer(allocator), value);
    return out.toOwnedSlice(allocator);
}

pub fn encodeToWriter(allocator: Allocator, writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .int => {
            if (value == 0) {
                try writer.writeByte(0x80);
                return;
            }
            var buf: [32]u8 = undefined;
            const bytes = intToBytes(value, &buf);
            if (bytes.len == 1 and bytes[0] < 0x80) {
                try writer.writeByte(bytes[0]);
            } else {
                try encodeString(allocator, writer, bytes);
            }
        },
        .pointer => |p| {
            if (p.child == u8 and p.size == .slice) {
                try encodeString(allocator, writer, value);
            } else if (p.size == .slice) {
                // Slice of non-u8 items - encode as list
                try encodeList(allocator, writer, value);
            } else if (p.size == .one) {
                try encodeToWriter(allocator, writer, value.*);
            } else {
                @compileError("Unsupported pointer type for RLP encoding: " ++ @typeName(T));
            }
        },
        .array => |a| {
            if (a.child == u8) {
                try encodeString(allocator, writer, &value);
            } else {
                try encodeList(allocator, writer, value);
            }
        },
        .@"struct" => {
            // Special case: if the struct has a single field named 'bytes', encode it as a string
            if (info.@"struct".fields.len == 1 and std.mem.eql(u8, info.@"struct".fields[0].name, "bytes")) {
                try encodeToWriter(allocator, writer, @field(value, info.@"struct".fields[0].name));
                return;
            }
            // For other structs, we encode all fields as a list.
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            inline for (info.@"struct".fields) |field| {
                try encodeToWriter(allocator, w, @field(value, field.name));
            }
            try encodeListHeader(writer, buf.items.len);
            try writer.writeAll(buf.items);
        },
        .optional => {
            if (value) |v| {
                try encodeToWriter(allocator, writer, v);
            } else {
                try writer.writeByte(0x80); // Empty string for null/optional
            }
        },
        else => @compileError("Unsupported type for RLP encoding: " ++ @typeName(T)),
    }
}

fn intToBytes(value: anytype, buf: []u8) []const u8 {
    const T = @TypeOf(value);
    const size = @sizeOf(T);
    std.mem.writeInt(T, buf[0..size], value, .big);
    var start: usize = 0;
    while (start < size and buf[start] == 0) : (start += 1) {}
    return buf[start..size];
}

fn encodeString(allocator: Allocator, writer: anytype, bytes: []const u8) !void {
    _ = allocator;
    if (bytes.len == 1 and bytes[0] < 0x80) {
        try writer.writeByte(bytes[0]);
    } else if (bytes.len <= 55) {
        try writer.writeByte(0x80 + @as(u8, @intCast(bytes.len)));
        try writer.writeAll(bytes);
    } else {
        var len_buf: [8]u8 = undefined;
        const len_bytes = intToBytes(bytes.len, &len_buf);
        try writer.writeByte(0xb7 + @as(u8, @intCast(len_bytes.len)));
        try writer.writeAll(len_bytes);
        try writer.writeAll(bytes);
    }
}

fn encodeList(allocator: Allocator, writer: anytype, items: anytype) !void {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    for (items) |item| {
        try encodeToWriter(allocator, w, item);
    }
    try encodeListHeader(writer, buf.items.len);
    try writer.writeAll(buf.items);
}

fn encodeListHeader(writer: anytype, len: usize) !void {
    if (len <= 55) {
        try writer.writeByte(0xc0 + @as(u8, @intCast(len)));
    } else {
        var len_buf: [8]u8 = undefined;
        const len_bytes = intToBytes(len, &len_buf);
        try writer.writeByte(0xf7 + @as(u8, @intCast(len_bytes.len)));
        try writer.writeAll(len_bytes);
    }
}

// --- Decoding ---

pub fn decode(allocator: Allocator, T: type, payload: []const u8) !T {
    var pos: usize = 0;
    return decodeRecursive(allocator, T, payload, &pos);
}

fn decodeRecursive(allocator: Allocator, T: type, payload: []const u8, pos: *usize) !T {
    const info = @typeInfo(T);

    switch (info) {
        .int => {
            const bytes = try decodeStringRaw(payload, pos);
            if (bytes.len == 0) return 0;
            if (bytes.len > @sizeOf(T)) return Error.Overflow;

            // Build the integer from big-endian bytes at runtime
            var result: T = 0;
            for (bytes) |b| {
                result = (result << 8) | @as(T, b);
            }
            return result;
        },
        .pointer => |p| {
            if (p.child == u8 and p.size == .slice) {
                const bytes = try decodeStringRaw(payload, pos);
                return try allocator.dupe(u8, bytes);
            } else if (p.size == .slice) {
                // Decode as a list of items
                const list_bytes = try decodeListRaw(payload, pos);
                var list_pos: usize = 0;
                var items = std.ArrayListUnmanaged(p.child){};
                errdefer items.deinit(allocator);

                while (list_pos < list_bytes.len) {
                    const item = try decodeRecursive(allocator, p.child, list_bytes, &list_pos);
                    try items.append(allocator, item);
                }
                return items.toOwnedSlice(allocator);
            }
            @compileError("Unsupported pointer type for RLP decoding: " ++ @typeName(T));
        },
        .array => |a| {
            if (a.child == u8) {
                const bytes = try decodeStringRaw(payload, pos);
                if (bytes.len != a.len) return Error.InvalidInput;
                var res: [a.len]u8 = undefined;
                @memcpy(&res, bytes);
                return res;
            } else {
                return try decodeList(allocator, T, payload, pos);
            }
        },
        .@"struct" => {
            // Special case: if the struct has a single field named 'bytes', decode it as raw bytes
            if (info.@"struct".fields.len == 1 and std.mem.eql(u8, info.@"struct".fields[0].name, "bytes")) {
                const field_type = info.@"struct".fields[0].type;
                var res: T = undefined;
                @field(res, info.@"struct".fields[0].name) = try decodeRecursive(allocator, field_type, payload, pos);
                return res;
            }
            const list_bytes = try decodeListRaw(payload, pos);
            var list_pos: usize = 0;
            var res: T = undefined;
            inline for (info.@"struct".fields) |field| {
                @field(res, field.name) = try decodeRecursive(allocator, field.type, list_bytes, &list_pos);
            }
            return res;
        },
        .optional => |o| {
            if (pos.* >= payload.len) return Error.UnexpectedEnd;
            if (payload[pos.*] == 0x80) {
                pos.* += 1;
                return null;
            }
            return try decodeRecursive(allocator, o.child, payload, pos);
        },
        else => @compileError("Unsupported type for RLP decoding: " ++ @typeName(T)),
    }
}

fn decodeStringRaw(payload: []const u8, pos: *usize) ![]const u8 {
    if (pos.* >= payload.len) return Error.UnexpectedEnd;
    const b = payload[pos.*];
    if (b < 0x80) {
        pos.* += 1;
        return payload[pos.* - 1 .. pos.*];
    } else if (b <= 0xb7) {
        const len = b - 0x80;
        pos.* += 1;
        if (pos.* + len > payload.len) return Error.UnexpectedEnd;
        const res = payload[pos.* .. pos.* + len];
        pos.* += len;
        return res;
    } else if (b <= 0xbf) {
        const len_of_len = b - 0xb7;
        pos.* += 1;
        if (pos.* + len_of_len > payload.len) return Error.UnexpectedEnd;
        const len = try bytesToUint(payload[pos.* .. pos.* + len_of_len]);
        pos.* += len_of_len;
        if (pos.* + len > payload.len) return Error.UnexpectedEnd;
        const res = payload[pos.* .. pos.* + len];
        pos.* += len;
        return res;
    } else {
        return Error.InvalidInput;
    }
}

fn decodeListRaw(payload: []const u8, pos: *usize) ![]const u8 {
    if (pos.* >= payload.len) return Error.UnexpectedEnd;
    const b = payload[pos.*];
    if (b < 0xc0) return Error.InvalidInput;

    if (b <= 0xf7) {
        const len = b - 0xc0;
        pos.* += 1;
        if (pos.* + len > payload.len) return Error.UnexpectedEnd;
        const res = payload[pos.* .. pos.* + len];
        pos.* += len;
        return res;
    } else {
        const len_of_len = b - 0xf7;
        pos.* += 1;
        if (pos.* + len_of_len > payload.len) return Error.UnexpectedEnd;
        const len = try bytesToUint(payload[pos.* .. pos.* + len_of_len]);
        pos.* += len_of_len;
        if (pos.* + len > payload.len) return Error.UnexpectedEnd;
        const res = payload[pos.* .. pos.* + len];
        pos.* += len;
        return res;
    }
}

fn decodeList(allocator: Allocator, T: type, payload: []const u8, pos: *usize) !T {
    const list_bytes = try decodeListRaw(payload, pos);
    var list_pos: usize = 0;
    const a = @typeInfo(T).array;

    var res: T = undefined;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        res[i] = try decodeRecursive(allocator, a.child, list_bytes, &list_pos);
    }
    return res;
}

fn bytesToUint(bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;
    if (bytes.len > 8) return Error.TooLarge;
    var res: usize = 0;
    for (bytes) |b| {
        res = (res << 8) | b;
    }
    return res;
}

test "RLP Roundtrip" {
    const ally = std.testing.allocator;
    const MyStruct = struct {
        a: u64,
        b: []const u8,
        c: [4]u8,
    };

    const s = MyStruct{ .a = 123, .b = "hello", .c = [_]u8{ 1, 2, 3, 4 } };
    const encoded = try encode(ally, s);
    defer ally.free(encoded);

    const decoded = try decode(ally, MyStruct, encoded);
    defer ally.free(decoded.b);

    try std.testing.expectEqual(s.a, decoded.a);
    try std.testing.expectEqualSlices(u8, s.b, decoded.b);
    try std.testing.expectEqualSlices(u8, &s.c, &decoded.c);
}
