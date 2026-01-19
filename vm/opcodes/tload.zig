// File: src/opcodes/tload.zig
// TLOAD (0x5c): Load word from transient storage
// Stack: key -> value
// EIP-1153: Transient storage opcodes

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.TLOAD),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const key = evm.stack.pop() orelse return error.StackUnderflow;

    // Get transient storage for current address
    // We mock "current_address" context lookup - in a real scenario this maps to the active account context
    if (evm.transient_storage.getPtr(evm.current_address)) |contract_storage| {
        if (contract_storage.get(key.to(u256))) |value| {
            // Convert u256 result back to BigInt
            var bi = BigInt.zero();
            // TODO: Optimize BigInt init from u256
            const bytes: [32]u8 = @bitCast(@byteSwap(value)); // BigInt.fromBytes expects BE
            bi = BigInt.fromBytes(bytes);
            try evm.stack.push(evm.allocator, bi);
            return;
        }
    }

    // Default 0 if not found
    try evm.stack.push(evm.allocator, BigInt.zero());
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // TLOAD: key -> value
    if (stack_top.* < 1) return error.StackUnderflow;
    const key_sidx = stack_top.* - 1;

    try jit.materialize_slot(@intCast(key_sidx));
    const key_slot = jit.get_virtual_slot(@intCast(key_sidx));
    const key_reg = switch (key_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    // Reuse slot for result
    // Registers are updated in-place (key_reg now holds val)
    try jit.emit_native_tload(key_reg, key_reg);
}
