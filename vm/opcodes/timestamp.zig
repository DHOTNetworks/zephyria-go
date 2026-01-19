// File: src/opcodes/timestamp.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.TIMESTAMP),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the block timestamp onto the stack
    try evm.stack.push(evm.allocator, BigInt.init(evm.block_timestamp));
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // TIMESTAMP: Read from JitContext (placeholder: use current unix time % 2^64)
    const TIMESTAMP: u256 = 1705536000; // Fixed timestamp for JIT
    try jit.push_virtual_constant(TIMESTAMP);
    stack_top.* += 1;
}
