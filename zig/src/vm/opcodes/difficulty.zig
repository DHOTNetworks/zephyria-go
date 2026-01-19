// File: src/opcodes/difficulty.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.DIFFICULTY),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the block difficulty onto the stack
    try evm.stack.push(evm.allocator, evm.block_difficulty);
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // DIFFICULTY (PREVRANDAO post-merge) - placeholder random value
    const PREVRANDAO: u256 = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    try jit.push_virtual_constant(PREVRANDAO);
    stack_top.* += 1;
}
