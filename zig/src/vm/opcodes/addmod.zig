// File: src/opcodes/addmod.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.ADDMOD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |n| {
        if (evm.stack.pop()) |b| {
            if (evm.stack.pop()) |a| {
                // Check for modulo by zero
                if (n.isZero()) {
                    try evm.stack.push(evm.allocator, BigInt.init(0));
                } else {
                    // (a + b) % n
                    const sum = a.add(b);
                    const result = sum.mod(n);
                    try evm.stack.push(evm.allocator, result);
                }
            } else return error.StackUnderflow;
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 3) return error.StackUnderflow;
    const a_idx = stack_top.* - 1;
    const b_idx = stack_top.* - 2;
    const n_idx = stack_top.* - 3;

    const v_a = jit.get_virtual_slot(@intCast(a_idx));
    const v_b = jit.get_virtual_slot(@intCast(b_idx));
    const v_n = jit.get_virtual_slot(@intCast(n_idx));

    // Constant folding
    if (v_a == .constant and v_b == .constant and v_n == .constant) {
        const n = v_n.constant;
        var result: u256 = 0;
        if (n != 0) {
            // Use wrapping add then mod
            const sum = v_a.constant +% v_b.constant;
            result = sum % n;
        }
        jit.pop_virtual(3);
        try jit.push_virtual_constant(result);
        stack_top.* -= 2;
        return;
    }

    // Dynamic case: emit native code
    try jit.materialize_slot(@intCast(a_idx));
    try jit.materialize_slot(@intCast(b_idx));
    try jit.materialize_slot(@intCast(n_idx));

    const a_slot = jit.get_virtual_slot(@intCast(a_idx));
    const b_slot = jit.get_virtual_slot(@intCast(b_idx));
    const n_slot = jit.get_virtual_slot(@intCast(n_idx));

    try jit.emit_native_addmod(n_slot.register, a_slot.register, b_slot.register, n_slot.register);
    jit.pop_virtual(2);
    stack_top.* -= 2;
}
