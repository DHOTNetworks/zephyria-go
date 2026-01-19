const std = @import("std");
const GlobalState = @import("storage").state.GlobalState;
const JitContext = @import("luffy/luffy.zig").JitContext;

pub export fn evm_sload(ctx: *anyopaque, key_ptr: *const [32]u8, res_ptr: *[32]u8) callconv(.c) void {
    const jit_ctx: *JitContext = @ptrCast(@alignCast(ctx));
    const state: *GlobalState = @ptrCast(@alignCast(jit_ctx.db));

    // address from context
    const val = state.getStorage(jit_ctx.address, key_ptr.*) catch |err| {
        std.debug.print("Error in evm_sload: {s}\n", .{@errorName(err)});
        @memset(res_ptr, 0);
        return;
    };
    @memcpy(res_ptr, &val);
}

pub export fn evm_sstore(ctx: *anyopaque, key_ptr: *const [32]u8, val_ptr: *const [32]u8) callconv(.c) void {
    const jit_ctx: *JitContext = @ptrCast(@alignCast(ctx));
    const state: *GlobalState = @ptrCast(@alignCast(jit_ctx.db));

    state.putStorage(jit_ctx.address, key_ptr.*, val_ptr.*) catch |err| {
        std.debug.print("Error in evm_sstore: {s}\n", .{@errorName(err)});
        return;
    };
}
