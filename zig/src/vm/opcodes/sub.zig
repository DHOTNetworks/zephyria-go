// File: src/opcodes/sub.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.SUB),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // EVM: SUB pops a (TOS), then b, computes a - b
    if (evm.stack.pop()) |a| {
        if (evm.stack.pop()) |b| {
            try evm.stack.push(evm.allocator, a.sub(b));
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const s1_idx = stack_top.* - 1; // b (top)
    const s2_idx = stack_top.* - 2; // a (second)

    try jit.emit_stencil("Sub", &.{
        .{ .symbol = "_HOLE_SRC1", .value = s2_idx },
        .{ .symbol = "_HOLE_SRC2", .value = s1_idx },
        .{ .symbol = "_HOLE_DST", .value = s2_idx },
    });
    jit.pop_virtual(2);
    try jit.push_virtual_memory();
    stack_top.* -= 1;
}
