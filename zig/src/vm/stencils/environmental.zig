const std = @import("std");
const JitContext = @import("context.zig").JitContext;

extern const HOLE_DST: u64;
extern const HOLE_SRC1: u64;
extern const HOLE_SRC2: u64;

export fn stencil_calldatacopy(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    const dest_offset = @as(usize, @truncate(stack[HOLE_DST]));
    const data_offset = @as(usize, @truncate(stack[HOLE_SRC1]));
    const size = @as(usize, @truncate(stack[HOLE_SRC2]));

    var i: usize = 0;
    while (i < size) : (i += 1) {
        const byte: u8 = if (data_offset + i < ctx.calldata_len) ctx.calldata_ptr[data_offset + i] else 0;
        if (dest_offset + i < ctx.memory_len) {
            ctx.memory_ptr[dest_offset + i] = byte;
        }
    }
}

export fn stencil_address(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    var val: u256 = 0;
    for (ctx.address, 0..) |byte, i| {
        val |= @as(u256, byte) << @intCast(i * 8);
    }
    stack[HOLE_DST] = val;
}

export fn stencil_caller(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    var val: u256 = 0;
    for (ctx.caller, 0..) |byte, i| {
        val |= @as(u256, byte) << @intCast(i * 8);
    }
    stack[HOLE_DST] = val;
}

export fn stencil_origin(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    var val: u256 = 0;
    for (ctx.origin, 0..) |byte, i| {
        val |= @as(u256, byte) << @intCast(i * 8);
    }
    stack[HOLE_DST] = val;
}

export fn stencil_callvalue(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    // call_value is 32 bytes
    var val: u256 = 0;
    for (ctx.call_value, 0..) |byte, i| {
        val |= @as(u256, byte) << @intCast(i * 8);
    }
    stack[HOLE_DST] = val;
}

export fn stencil_calldatasize(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    stack[HOLE_DST] = @as(u256, ctx.calldata_len);
}

export fn stencil_calldataload(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    const offset = @as(usize, @truncate(stack[HOLE_DST]));

    var val: u256 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const byte: u8 = if (offset + i < ctx.calldata_len) ctx.calldata_ptr[offset + i] else 0;
        // EVM is big-endian, so first byte is MSB?
        // Actually, CALLDATALOAD reads 32 bytes and packs them so the first byte is the most significant.
        val = (val << 8) | byte;
    }
    stack[HOLE_DST] = val;
}
