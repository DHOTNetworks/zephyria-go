// File: src/opcodes/jump.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.JUMP),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |dest| {
        const dest_pc = @as(usize, @intCast(dest.to(u64)));
        if (dest_pc >= evm.code.len or evm.code[dest_pc] != @intFromEnum(Opcode.JUMPDEST)) {
            return error.InvalidJumpDest;
        }
        evm.pc = dest_pc;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    // const target = stack_top.* - 1; // Needs dynamic logic
    // For now, dummy
    try jit.compile_jump(0);
    stack_top.* -= 1;
}
