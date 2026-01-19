// File: src/opcodes/codesize.zig
// CODESIZE (0x38): Get size of code running in current environment
// Stack: -> size
// Pushes the size of the currently executing contract's code

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CODESIZE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    try evm.stack.push(evm.allocator, BigInt.init(evm.code.len));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    // CODESIZE pushes the length of the bytecode
    try jit.push_virtual_constant(@as(u256, bytecode.len));
    stack_top.* += 1;
}
