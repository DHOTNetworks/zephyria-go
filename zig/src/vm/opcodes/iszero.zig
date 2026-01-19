// File: src/opcodes/iszero.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.ISZERO),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |a| {
        try evm.stack.push(evm.allocator, if (a.isZero()) @import("../main.zig").BigInt.init(1) else @import("../main.zig").BigInt.init(0));
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1;
    const v1 = jit.get_virtual_slot(@intCast(s1_idx));

    // Constant Folding
    if (v1 == .constant) {
        const res: u256 = if (v1.constant == 0) 1 else 0;
        jit.pop_virtual(1);
        try jit.push_virtual_constant(res);
        return;
    }

    try jit.materialize_slot(@intCast(s1_idx));
    const s1_slot = jit.get_virtual_slot(@intCast(s1_idx));
    const s1_reg = switch (s1_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    try jit.emit_native_iszero(s1_reg, s1_reg);
    // Stack size unchanged
}
