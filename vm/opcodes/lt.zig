// File: src/opcodes/lt.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.LT),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // EVM: LT pops a (TOS), then b, pushes a < b
    if (evm.stack.pop()) |a| {
        if (evm.stack.pop()) |b| {
            try evm.stack.push(evm.allocator, if (a.lt(b)) @import("../main.zig").BigInt.init(1) else @import("../main.zig").BigInt.init(0));
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1; // b (TOS)
    const s2_idx = stack_top.* - 2; // a (TOS-1)

    const v1 = jit.get_virtual_slot(@intCast(s1_idx));
    const v2 = jit.get_virtual_slot(@intCast(s2_idx));

    // Constant Folding: a < b
    if (v1 == .constant and v2 == .constant) {
        const res: u256 = if (v1.constant < v2.constant) 1 else 0;
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

    // LT: a < b where a=TOS (s1), b=TOS-1 (s2) -> emit_native_lt(dst, a, b)
    try jit.emit_native_lt(s2_reg, s1_reg, s2_reg);
    jit.pop_virtual(1);
    stack_top.* -= 1;
}
