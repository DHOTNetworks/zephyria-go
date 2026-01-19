// File: src/opcodes/codecopy.zig
// CODECOPY (0x39): Copy code running in current environment to memory
// Stack: destOffset, offset, size -> (none)
// Copies 'size' bytes of code from 'offset' to memory at 'destOffset'
// Pads with zeros if reading beyond code length

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CODECOPY),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const dest_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const code_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;

    // Convert to usize with bounds checking
    if (!size_big.fitsInU64()) return;
    const size: usize = @intCast(size_big.data[0]);
    if (size == 0) return;

    if (!dest_offset_big.fitsInU64()) return error.OutOfGas;
    const dest_offset: usize = @intCast(dest_offset_big.data[0]);

    const code_offset: usize = if (code_offset_big.fitsInU64())
        @intCast(@min(code_offset_big.data[0], evm.code.len))
    else
        evm.code.len;

    // Expand memory if needed
    try evm.memory.ensureCapacity(evm.allocator, dest_offset + size);

    // Copy from code to memory, with zero padding
    for (0..size) |i| {
        const src_idx = code_offset + i;
        const byte: u8 = if (src_idx < evm.code.len) evm.code[src_idx] else 0;
        try evm.memory.storeByte(evm.allocator, dest_offset + i, byte);
    }
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 3) return error.StackUnderflow;
    // CODECOPY: destOffset, offset, length -> void
    if (stack_top.* < 3) return error.StackUnderflow;
    const size_idx = stack_top.* - 1;
    const offset_idx = stack_top.* - 2;
    const destOffset_idx = stack_top.* - 3;

    try jit.materialize_slot(size_idx);
    try jit.materialize_slot(offset_idx);
    try jit.materialize_slot(destOffset_idx);

    const destOffset_slot = jit.get_virtual_slot(@intCast(destOffset_idx));
    const offset_slot = jit.get_virtual_slot(@intCast(offset_idx));
    const size_slot = jit.get_virtual_slot(@intCast(size_idx));

    try jit.emit_native_codecopy(destOffset_slot.register, offset_slot.register, size_slot.register);
    jit.pop_virtual(3);
    stack_top.* -= 3;
}
