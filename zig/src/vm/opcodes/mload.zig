// File: src/opcodes/mload.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.MLOAD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    if (!offset_big.fitsInU64()) return error.OutOfGas;
    const offset: usize = @intCast(offset_big.data[0]);

    try evm.memory.ensureCapacity(evm.allocator, offset + 32);
    const bytes = try evm.memory.load(evm.allocator, offset, 32);
    var bytes32: [32]u8 = undefined;
    @memcpy(&bytes32, bytes);
    try evm.stack.push(evm.allocator, BigInt.fromBytes(bytes32));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    const offset_sidx = stack_top.* - 1;

    try jit.materialize_slot(@intCast(offset_sidx));
    const o_slot = jit.get_virtual_slot(@intCast(offset_sidx));
    const o_reg = switch (o_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    // Reuse slot for result? No, MLOAD pops 1 (offset), pushes 1 (value).
    // Stack top (offset) is consumed.
    // We can reuse the register bank if we want, OR pop and push new.
    // Logic:
    // Offset is at stack_top - 1.
    // We need a register for result.
    // Offset reg is free after use?
    // MLOAD is: Stack: offset -> value.
    // Same slot.
    // So we load 'offset', use it, and overwrite register with result.
    try jit.emit_native_mload(o_reg, o_reg);

    // MLOAD: offset is consumed, value is pushed. Length unchanged.
    // However, metadata must be updated to memory.
    jit.pop_virtual(1);
    try jit.push_virtual_memory();
}
