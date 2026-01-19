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
    // MSTORE8: Stack order pops offset first (top), then value.
    // stack_top-1 = top = offset
    // stack_top-2 = value
    if (stack_top.* < 2) return error.StackUnderflow;
    const offset_idx = stack_top.* - 1;
    const val_idx = stack_top.* - 2;

    try jit.materialize_slot(offset_idx);
    try jit.materialize_slot(val_idx);

    const offset_slot = jit.get_virtual_slot(@intCast(offset_idx));
    const val_slot = jit.get_virtual_slot(@intCast(val_idx));

    try jit.emit_native_mstore8(offset_slot.register, val_slot.register);
    jit.pop_virtual(2);
    stack_top.* -= 2;
}
