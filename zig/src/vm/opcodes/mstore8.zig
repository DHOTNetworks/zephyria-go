// File: src/opcodes/mstore8.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.MSTORE8),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const value_big = evm.stack.pop() orelse return error.StackUnderflow;

    if (!offset_big.fitsInU64()) return error.OutOfGas;
    const offset: usize = @intCast(offset_big.data[0]);

    const value: u8 = @truncate(value_big.data[0]);
    try evm.memory.ensureCapacity(evm.allocator, offset + 1);
    try evm.memory.storeByte(evm.allocator, offset, value);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1 = stack_top.* - 1; // value
    const s2 = stack_top.* - 2; // offset
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Mstore8, &.{
        .{ .symbol = "_HOLE_DST", .value = s1 },
        .{ .symbol = "_HOLE_SRC1", .value = s2 },
    });
    stack_top.* -= 2;
}
