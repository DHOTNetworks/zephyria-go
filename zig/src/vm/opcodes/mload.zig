// File: src/opcodes/mload.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.MLOAD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    if (!offset_big.fitsInU64()) return error.OutOfGas;
    const offset: usize = @intCast(offset_big.data[0]);

    try evm.memory.ensureCapacity(evm.allocator, offset + 32);
    const bytes = try evm.memory.load(evm.allocator, offset, 32);
    var bytes32: [32]u8 = undefined;
    @memcpy(&bytes32, bytes);
    try evm.stack.push(evm.allocator, BigInt.fromBytes(bytes32));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    const s1 = stack_top.* - 1;
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Mload, &.{
        .{ .symbol = "_HOLE_DST", .value = s1 },
    });
}
