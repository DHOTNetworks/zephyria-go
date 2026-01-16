// File: src/opcodes/push1.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.PUSH1),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.pc >= evm.code.len) {
        return error.InvalidCode;
    }
    const value = evm.code[evm.pc];
    evm.pc += 1;
    try evm.stack.push(evm.allocator, BigInt.init(value));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    if (pc.* >= bytecode.len) return error.InvalidCode;
    const value = bytecode[pc.*];
    pc.* += 1;

    try jit.compile_push(stack_top.*, @as(u256, value));
    stack_top.* += 1;
}
