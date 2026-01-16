// File: src/opcodes/eq.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.EQ),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |b| {
        if (evm.stack.pop()) |a| {
            try evm.stack.push(evm.allocator, if (a.eq(b)) @import("../main.zig").BigInt.init(1) else @import("../main.zig").BigInt.init(0));
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1 = stack_top.* - 1;
    const s2 = stack_top.* - 2;
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Eq, &.{
        .{ .symbol = "_HOLE_DST", .value = s2 },
        .{ .symbol = "_HOLE_SRC1", .value = s1 },
        .{ .symbol = "_HOLE_SRC2", .value = s2 },
    });
    stack_top.* -= 1;
}
