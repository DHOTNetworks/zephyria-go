const std = @import("std");

extern const HOLE_DST: u64; // Stack index to write to
extern const HOLE_VAL: u256; // Immediate value to push

export fn stencil_push(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    // PUSH <val> -> stack[DST] = val
    // The JIT determines 'DST' (allocates a slot).
    stack[HOLE_DST] = HOLE_VAL;
}

// POP is often specific in a register-mapped JIT.
// If we just discard a value, we don't need code unless we need to handle side-effects (none for POP usually).
// However, if we need to move the top-of-stack pointer or similar, it might matter.
// In this design (random access stack slots), POP just means "freeing" a slot in the compilation logic.
// But we might need a stencil if we were doing a pure stack-machine implementation.
// For now, let's keep it simple. If we need to move data:
extern const HOLE_SRC: u64;
export fn stencil_move(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    // stack[DST] = stack[SRC]
    stack[HOLE_DST] = stack[HOLE_SRC];
}

export fn stencil_swap(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    // Swap stack[DST] and stack[SRC]
    const tmp = stack[HOLE_DST];
    stack[HOLE_DST] = stack[HOLE_SRC];
    stack[HOLE_SRC] = tmp;
}
