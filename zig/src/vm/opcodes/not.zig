// File: src/opcodes/not.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.NOT),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |a| {
        try evm.stack.push(evm.allocator, a.bitNot());
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1;

    const v1 = jit.get_virtual_slot(@intCast(s1_idx));

    // 1. Constant Folding
    if (v1 == .constant) {
        const res = ~v1.constant;
        jit.pop_virtual(1);
        try jit.push_virtual_constant(res);
        return;
    }

    // 2. Native Emission
    try jit.materialize_slot(@intCast(s1_idx));

    const s1_slot = jit.get_virtual_slot(@intCast(s1_idx));
    const s1_reg = switch (s1_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    try jit.emit_native_not(s1_reg, s1_reg);
}
