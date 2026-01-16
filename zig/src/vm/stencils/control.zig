const std = @import("std");

extern fn HOLE_TARGET() void;
extern const HOLE_COND: u64; // Stack index for condition

export fn stencil_jump(stack: [*]u256, evm: *anyopaque) void {
    _ = stack;
    _ = evm;
    // Unconditional Jump
    // Compiler should emit a Branch (B) or Branch with Link (BL) to HOLE_TARGET
    HOLE_TARGET();
}

export fn stencil_jumpi(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    // Conditional Jump
    // stack[HOLE_COND] is the condition value (u256)
    // If condition != 0, Jump.
    const cond = stack[HOLE_COND];
    if (cond > 0) {
        HOLE_TARGET();
    }
}

export fn stencil_jumpdest(stack: [*]u256, evm: *anyopaque) void {
    _ = stack;
    _ = evm;
    // No-op. Just a marker.
    // Logic: Do nothing.
    asm volatile ("nop");
}
