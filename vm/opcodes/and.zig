// File: src/opcodes/and.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.AND),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |b| {
        if (evm.stack.pop()) |a| {
            try evm.stack.push(evm.allocator, a.bitAnd(b));
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1;
    const s2_idx = stack_top.* - 2;

    const v1 = jit.get_virtual_slot(@intCast(s1_idx));
    const v2 = jit.get_virtual_slot(@intCast(s2_idx));

    // 1. Constant Folding
    if (v1 == .constant and v2 == .constant) {
        const res = v2.constant & v1.constant;
        jit.pop_virtual(2);
        try jit.push_virtual_constant(res);
        stack_top.* -= 1;
        return;
    }

    // 2. Native Emission
    try jit.materialize_slot(@intCast(s1_idx));
    try jit.materialize_slot(@intCast(s2_idx));

    const s1_slot = jit.get_virtual_slot(@intCast(s1_idx));
    const s2_slot = jit.get_virtual_slot(@intCast(s2_idx));

    const s1_reg = switch (s1_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };
    const s2_reg = switch (s2_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    try jit.emit_native_and(s2_reg, s2_reg, s1_reg);
    jit.pop_virtual(1);
    stack_top.* -= 1;
}
