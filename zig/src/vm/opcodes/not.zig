// File: src/opcodes/not.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.NOT),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |a| {
        try evm.stack.push(evm.allocator, a.bitNot());
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    const s1 = stack_top.* - 1;
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Not, &.{
        .{ .symbol = "_HOLE_DST", .value = s1 },
        .{ .symbol = "_HOLE_SRC1", .value = s1 },
    });
}
