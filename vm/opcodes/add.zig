// File: src/opcodes/add.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.ADD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |b| {
        if (evm.stack.pop()) |a| {
            try evm.stack.push(evm.allocator, a.add(b));
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1;
    const s2_idx = stack_top.* - 2;

    try jit.emit_stencil("Add", &.{
        .{ .symbol = "_HOLE_SRC1", .value = s1_idx },
        .{ .symbol = "_HOLE_SRC2", .value = s2_idx },
        .{ .symbol = "_HOLE_DST", .value = s2_idx },
    });
    jit.pop_virtual(2);
    try jit.push_virtual_memory();
    stack_top.* -= 1;
}
