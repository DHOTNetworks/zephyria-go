// File: src/opcodes/calldataload.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CALLDATALOAD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const offset: usize = if (offset_big.fitsInU64())
        @intCast(@min(offset_big.data[0], evm.calldata.len))
    else
        evm.calldata.len;

    var bytes: [32]u8 = [_]u8{0} ** 32;
    const available = if (offset < evm.calldata.len)
        @min(32, evm.calldata.len - offset)
    else
        0;

    if (available > 0) {
        @memcpy(bytes[0..available], evm.calldata[offset .. offset + available]);
    }

    const result = BigInt.fromBytes(bytes);
    try evm.stack.push(evm.allocator, result);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    const s1 = stack_top.* - 1;
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Calldataload, &.{
        .{ .symbol = "_HOLE_DST", .value = s1 },
    });
}
