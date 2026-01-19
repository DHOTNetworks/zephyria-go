// File: src/opcodes/gasprice.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.GASPRICE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the gas price onto the stack
    try evm.stack.push(evm.allocator, evm.gas_price);
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    const GAS_PRICE: u256 = 1_000_000_000; // 1 gwei
    try jit.push_virtual_constant(GAS_PRICE);
    stack_top.* += 1;
}
