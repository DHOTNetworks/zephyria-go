// File: src/opcodes/calldatacopy.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CALLDATACOPY),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const dest_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const data_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;

    if (!size_big.fitsInU64()) return;
    const size: usize = @intCast(size_big.data[0]);
    if (size == 0) return;

    if (!dest_offset_big.fitsInU64()) return error.OutOfGas;
    const dest_offset: usize = @intCast(dest_offset_big.data[0]);

    const data_offset: usize = if (data_offset_big.fitsInU64())
        @intCast(@min(data_offset_big.data[0], evm.calldata.len))
    else
        evm.calldata.len;

    try evm.memory.ensureCapacity(evm.allocator, dest_offset + size);
    for (0..size) |i| {
        const src_idx = data_offset + i;
        const byte: u8 = if (src_idx < evm.calldata.len)
            evm.calldata[src_idx]
        else
            0;
        try evm.memory.storeByte(evm.allocator, dest_offset + i, byte);
    }
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 3) return error.StackUnderflow;
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Calldatacopy, &.{
        .{ .symbol = "_HOLE_DST", .value = stack_top.* - 1 },
        .{ .symbol = "_HOLE_SRC1", .value = stack_top.* - 2 },
        .{ .symbol = "_HOLE_SRC2", .value = stack_top.* - 3 },
    });
    stack_top.* -= 3;
}
