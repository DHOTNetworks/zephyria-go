// File: src/opcodes/basefee.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.BASEFEE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the base fee onto the stack
    try evm.stack.push(evm.allocator, evm.base_fee);
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    const BASE_FEE: u256 = 1_000_000_000; // 1 gwei base fee
    try jit.push_virtual_constant(BASE_FEE);
    stack_top.* += 1;
}
