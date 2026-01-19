// File: src/opcodes/callvalue.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CALLVALUE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    try evm.stack.push(evm.allocator, evm.call_value);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // CALLVALUE: Push transaction value from JitContext
    try jit.push_virtual_memory();
    stack_top.* += 1;
    try jit.materialize_slot(@intCast(stack_top.* - 1));
    const slot = jit.get_virtual_slot(@intCast(stack_top.* - 1));
    try jit.emit_native_callvalue(slot.register);
}
