// File: src/opcodes/pc.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.PC),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the current program counter onto the stack
    // Note: PC should be the value BEFORE the increment for this instruction
    const current_pc = evm.pc - 1; // Subtract 1 because PC was already incremented
    try evm.stack.push(evm.allocator, BigInt.init(@as(u64, @intCast(current_pc))));
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = bytecode;
    // PC pushes the program counter of the current instruction (before incrementing)
    // pc has already been incremented by 1 in the main loop, so we subtract 1
    const current_pc = pc.* - 1;
    try jit.push_virtual_constant(@as(u256, current_pc));
    stack_top.* += 1;
}
