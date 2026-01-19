const std = @import("std");

// Holes are INDICES into the stack.
// Stack is array of u256.
// Host architecture is 64-bit, so indices are u64.

extern const HOLE_SRC1: u64;
extern const HOLE_SRC2: u64;
extern const HOLE_DST: u64;

export fn stencil_add(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    const val1 = stack[HOLE_SRC1];
    const val2 = stack[HOLE_SRC2];
    const res = val1 +% val2;
    stack[HOLE_DST] = res;
}

export fn stencil_sub(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    const val1 = stack[HOLE_SRC1];
    const val2 = stack[HOLE_SRC2];
    const res = val1 -% val2;
    stack[HOLE_DST] = res;
}

export fn stencil_mul(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    const val1 = stack[HOLE_SRC1];
    const val2 = stack[HOLE_SRC2];
    const res = val1 *% val2;
    stack[HOLE_DST] = res;
}

export fn stencil_div(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    const val1 = stack[HOLE_SRC1];
    const val2 = stack[HOLE_SRC2];
    if (val2 == 0) {
        stack[HOLE_DST] = 0;
    } else {
        stack[HOLE_DST] = val1 / val2;
    }
}

export fn stencil_and(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = stack[HOLE_SRC1] & stack[HOLE_SRC2];
}

export fn stencil_or(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = stack[HOLE_SRC1] | stack[HOLE_SRC2];
}

export fn stencil_xor(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = stack[HOLE_SRC1] ^ stack[HOLE_SRC2];
}

export fn stencil_not(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = ~stack[HOLE_SRC1];
}

export fn stencil_iszero(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = if (stack[HOLE_SRC1] == 0) @as(u256, 1) else @as(u256, 0);
}

export fn stencil_eq(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = if (stack[HOLE_SRC1] == stack[HOLE_SRC2]) @as(u256, 1) else @as(u256, 0);
}

export fn stencil_lt(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = if (stack[HOLE_SRC1] < stack[HOLE_SRC2]) @as(u256, 1) else @as(u256, 0);
}

export fn stencil_gt(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    stack[HOLE_DST] = if (stack[HOLE_SRC1] > stack[HOLE_SRC2]) @as(u256, 1) else @as(u256, 0);
}

export fn stencil_slt(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    const s1 = @as(i256, @bitCast(stack[HOLE_SRC1]));
    const s2 = @as(i256, @bitCast(stack[HOLE_SRC2]));
    stack[HOLE_DST] = if (s1 < s2) @as(u256, 1) else @as(u256, 0);
}

export fn stencil_sgt(stack: [*]u256, evm: *anyopaque) void {
    _ = evm;
    const s1 = @as(i256, @bitCast(stack[HOLE_SRC1]));
    const s2 = @as(i256, @bitCast(stack[HOLE_SRC2]));
    stack[HOLE_DST] = if (s1 > s2) @as(u256, 1) else @as(u256, 0);
}
