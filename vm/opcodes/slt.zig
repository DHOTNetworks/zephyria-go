// File: src/opcodes/slt.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.SLT),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |b| {
        if (evm.stack.pop()) |a| {
            // Need to handle signed comparison
            const s1 = @as(i256, @bitCast(a.to(u256)));
            const s2 = @as(i256, @bitCast(b.to(u256)));
            try evm.stack.push(evm.allocator, if (s1 < s2) @import("../main.zig").BigInt.init(1) else @import("../main.zig").BigInt.init(0));
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

    // Constant Folding: signed a < b
    if (v1 == .constant and v2 == .constant) {
        const sa = @as(i256, @bitCast(v2.constant));
        const sb = @as(i256, @bitCast(v1.constant));
        const res: u256 = if (sa < sb) 1 else 0;
        jit.pop_virtual(2);
        try jit.push_virtual_constant(res);
        stack_top.* -= 1;
        return;
    }

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

    try jit.emit_native_slt(s2_reg, s2_reg, s1_reg);
    jit.pop_virtual(1);
    stack_top.* -= 1;
}
