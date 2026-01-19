// File: src/opcodes/returndatasize.zig
// RETURNDATASIZE (0x3d): Get size of return data from last call
// Stack: -> size
// Pushes the size of the return data buffer from the last external call

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.RETURNDATASIZE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const size = BigInt.init(@as(u64, evm.return_data.len));
    try evm.stack.push(evm.allocator, size);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // RETURNDATASIZE: Push size of last return data
    // For now, use 0 as default (no previous call)
    try jit.push_virtual_constant(0);
    stack_top.* += 1;
}
