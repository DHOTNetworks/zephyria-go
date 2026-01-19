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
    // CALLDATACOPY: destOffset, offset, length -> void
    if (stack_top.* < 3) return error.StackUnderflow;
    const size_idx = stack_top.* - 1;
    const offset_idx = stack_top.* - 2;
    const destOffset_idx = stack_top.* - 3;

    try jit.materialize_slot(size_idx); // length
    try jit.materialize_slot(offset_idx); // offset
    try jit.materialize_slot(destOffset_idx); // destOffset

    const destOffset_slot = jit.get_virtual_slot(@intCast(destOffset_idx));
    const offset_slot = jit.get_virtual_slot(@intCast(offset_idx));
    const size_slot = jit.get_virtual_slot(@intCast(size_idx));
    try jit.emit_native_calldatacopy(destOffset_slot.register, offset_slot.register, size_slot.register);
    jit.pop_virtual(3);
    stack_top.* -= 3;
}
