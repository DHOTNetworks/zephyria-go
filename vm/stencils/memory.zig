const std = @import("std");
const JitContext = @import("context.zig").JitContext;

extern const HOLE_DST: u64;
extern const HOLE_SRC1: u64;

export fn stencil_mload(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    // SFI: Truncate to 32-bit to ensure access is within 4GB relative block
    const offset = @as(u32, @truncate(stack[HOLE_DST]));

    if (@as(usize, offset) + 32 <= ctx.memory_len) {
        // Fast Path: Direct access
        const ptr = ctx.memory_ptr + offset;
        stack[HOLE_DST] = std.mem.readInt(u256, @ptrCast(ptr), .big);
    } else {
        // Slow Path: Partial read (OOB bytes are 0)
        var val: u256 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const byte: u8 = if (@as(usize, offset) + i < ctx.memory_len) ctx.memory_ptr[offset + i] else 0;
            val = (val << 8) | byte;
        }
        stack[HOLE_DST] = val;
    }
}

export fn stencil_mstore(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    // SFI: Truncate to 32-bit
    const offset = @as(u32, @truncate(stack[HOLE_SRC1]));
    const val = stack[HOLE_DST];

    if (@as(usize, offset) + 32 <= ctx.memory_len) {
        // Fast Path
        const ptr = ctx.memory_ptr + offset;
        std.mem.writeInt(u256, @ptrCast(ptr), val, .big);
    } else {
        // Slow Path: Partial write (TODO: Should trigger memory expansion)
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const byte: u8 = @truncate(val >> @intCast((31 - i) * 8));
            if (@as(usize, offset) + i < ctx.memory_len) {
                ctx.memory_ptr[offset + i] = byte;
            }
        }
    }
}

export fn stencil_mstore8(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    // SFI: Truncate to 32-bit
    const offset = @as(u32, @truncate(stack[HOLE_SRC1]));
    const val = stack[HOLE_DST];
    const byte: u8 = @truncate(val);

    if (@as(usize, offset) < ctx.memory_len) {
        ctx.memory_ptr[offset] = byte;
    }
}
