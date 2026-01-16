const std = @import("std");
const JitContext = @import("context.zig").JitContext;

extern const HOLE_DST: u64;
extern const HOLE_SRC1: u64;

export fn stencil_mload(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    const offset = @as(usize, @truncate(stack[HOLE_DST]));

    var val: u256 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const byte: u8 = if (offset + i < ctx.memory_len) ctx.memory_ptr[offset + i] else 0;
        val = (val << 8) | byte;
    }
    stack[HOLE_DST] = val;
}

export fn stencil_mstore(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    const offset = @as(usize, @truncate(stack[HOLE_SRC1]));
    const val = stack[HOLE_DST];

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const byte: u8 = @truncate(val >> @intCast((31 - i) * 8));
        if (offset + i < ctx.memory_len) {
            ctx.memory_ptr[offset + i] = byte;
        }
    }
}

export fn stencil_mstore8(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    const offset = @as(usize, @truncate(stack[HOLE_SRC1]));
    const val = stack[HOLE_DST];
    const byte: u8 = @truncate(val);
    if (offset < ctx.memory_len) {
        ctx.memory_ptr[offset] = byte;
    }
}
