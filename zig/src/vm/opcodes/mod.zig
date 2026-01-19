// File: src/opcodes/mod.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.MOD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // EVM: MOD pops a (TOS), then b, pushes a % b (0 if b=0)
    if (evm.stack.pop()) |a| {
        if (evm.stack.pop()) |b| {
            try evm.stack.push(evm.allocator, a.mod(b));
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1; // b (modulus)
    const s2_idx = stack_top.* - 2; // a (dividend)

    const v1 = jit.get_virtual_slot(s1_idx);
    const v2 = jit.get_virtual_slot(s2_idx);

    // 1. Constant Folding: a % b (EVM returns 0 for mod by 0)
    if (v1 == .constant and v2 == .constant) {
        const res = if (v1.constant == 0) 0 else v2.constant % v1.constant;
        jit.pop_virtual(2);
        try jit.push_virtual_constant(res);
        stack_top.* -= 1;
        return;
    }

    // 2. Native Emission
    try jit.materialize_slot(s1_idx);
    try jit.materialize_slot(s2_idx);
    const r1 = jit.get_virtual_slot(s1_idx).register;
    const r2 = jit.get_virtual_slot(s2_idx).register;

    try jit.emit_native_rem(r2, r2, r1);

    jit.pop_virtual(2);
    try jit.push_virtual_register(r2);
    stack_top.* -= 1;
}
