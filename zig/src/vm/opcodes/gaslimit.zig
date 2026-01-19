// File: src/opcodes/gaslimit.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.GASLIMIT),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the block gas limit onto the stack
    try evm.stack.push(evm.allocator, BigInt.init(evm.block_gas_limit));
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    const GAS_LIMIT: u256 = 30_000_000; // Standard block gas limit
    try jit.push_virtual_constant(GAS_LIMIT);
    stack_top.* += 1;
}
