// File: src/opcodes/chainid.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CHAINID),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the chain ID onto the stack
    try evm.stack.push(evm.allocator, BigInt.init(evm.chain_id));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // Chain ID is a compile-time constant (Zephyria mainnet = 1337 for now)
    const CHAIN_ID: u256 = 1337;
    try jit.push_virtual_constant(CHAIN_ID);
    stack_top.* += 1;
}
