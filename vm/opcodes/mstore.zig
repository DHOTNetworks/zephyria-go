// File: src/opcodes/mstore.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.MSTORE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const value = evm.stack.pop() orelse return error.StackUnderflow;

    if (!offset_big.fitsInU64()) return error.OutOfGas;
    const offset: usize = @intCast(offset_big.data[0]);

    try evm.memory.ensureCapacity(evm.allocator, offset + 32);
    const bytes = value.toBytes();
    try evm.memory.store(evm.allocator, offset, &bytes);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    // EVM: MSTORE pops offset (top), then value
    const offset_sidx = stack_top.* - 1; // offset is TOS
    const val_sidx = stack_top.* - 2; // value is TOS-1

    // MSTORE: offsets already materialized
    try jit.materialize_slot(@intCast(offset_sidx));
    try jit.materialize_slot(@intCast(val_sidx));

    // Get registers
    const o_slot = jit.get_virtual_slot(@intCast(offset_sidx));
    const v_slot = jit.get_virtual_slot(@intCast(val_sidx));

    // Unsafe extract: we assume materialization worked
    const o_reg = switch (o_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };
    const v_reg = switch (v_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    try jit.emit_native_mstore(o_reg, v_reg);

    jit.pop_virtual(2);
    stack_top.* -= 2;
}
