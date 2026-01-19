// File: src/opcodes/gas.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.GAS),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the remaining gas onto the stack
    try evm.stack.push(evm.allocator, BigInt.init(evm.gas));
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // GAS pushes remaining gas - use a large constant for JIT mode
    // In production, this would read from JitContext
    const REMAINING_GAS: u256 = 100_000_000;
    try jit.push_virtual_constant(REMAINING_GAS);
    stack_top.* += 1;
}
