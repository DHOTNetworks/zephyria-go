const std = @import("std");
const JitContext = @import("context.zig").JitContext;

extern const HOLE_SRC1: u64;
extern const HOLE_SRC2: u64;
extern const HOLE_DST: u64;

export fn stencil_sload(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    // stack[HOLE_SRC1] is the key.
    // We want to write result to HOLE_DST.
    const key_ptr: *const [32]u8 = @ptrCast(&stack[HOLE_SRC1]);
    const res_ptr: *[32]u8 = @ptrCast(&stack[HOLE_DST]);

    ctx.evm_sload(ctx_ptr, key_ptr, res_ptr);
}

export fn stencil_sstore(stack: [*]u256, ctx_ptr: *anyopaque) void {
    const ctx: *const JitContext = @ptrCast(@alignCast(ctx_ptr));
    const key_ptr: *const [32]u8 = @ptrCast(&stack[HOLE_SRC1]);
    const val_ptr: *const [32]u8 = @ptrCast(&stack[HOLE_SRC2]);

    ctx.evm_sstore(ctx_ptr, key_ptr, val_ptr);
}
