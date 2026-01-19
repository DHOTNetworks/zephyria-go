// File: src/opcodes/calldatasize.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CALLDATASIZE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const size = BigInt.init(@as(u64, evm.calldata.len));
    try evm.stack.push(evm.allocator, size);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    try jit.push_virtual_memory();
    stack_top.* += 1;
    try jit.emit_stencil("Calldatasize", &.{
        .{ .symbol = "_HOLE_DST", .value = stack_top.* - 1 },
    });
}
