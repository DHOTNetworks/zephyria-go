// File: src/opcodes/number.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.NUMBER),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the block number onto the stack
    try evm.stack.push(evm.allocator, BigInt.init(evm.block_number));
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // NUMBER: Push block number (placeholder for JIT)
    const BLOCK_NUMBER: u256 = 1;
    try jit.push_virtual_constant(BLOCK_NUMBER);
    stack_top.* += 1;
}
