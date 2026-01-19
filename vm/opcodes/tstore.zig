// File: src/opcodes/tstore.zig
// TSTORE (0x5d): Save word to transient storage
// Stack: key, value -> []
// EIP-1153: Transient storage opcodes

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.TSTORE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const key = evm.stack.pop() orelse return error.StackUnderflow;
    const value = evm.stack.pop() orelse return error.StackUnderflow;

    if (evm.call_stack.isStatic()) {
        return error.StaticCallViolation;
    }

    // Get or create transient storage for current address
    const result = try evm.transient_storage.getOrPut(evm.current_address);
    if (!result.found_existing) {
        result.value_ptr.* = std.AutoHashMap(u256, u256).init(evm.allocator);
    }

    // EIP-1153: gas cost is handled in main.zig (flat 100 gas)
    // No specific refunds or warm/cold logic for transient storage defined in EIP-1153 beyond the flat cost.
    try result.value_ptr.put(key.to(u256), value.to(u256));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // TSTORE: key, value -> []
    if (stack_top.* < 2) return error.StackUnderflow;
    const key_sidx = stack_top.* - 1; // Key is Top
    const val_sidx = stack_top.* - 2; // Val is Top-1

    try jit.materialize_slot(@intCast(key_sidx));
    try jit.materialize_slot(@intCast(val_sidx));

    const key_slot = jit.get_virtual_slot(@intCast(key_sidx));
    const val_slot = jit.get_virtual_slot(@intCast(val_sidx));

    const key_reg = switch (key_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };
    const val_reg = switch (val_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    try jit.emit_native_tstore(key_reg, val_reg);

    jit.pop_virtual(2);
    stack_top.* -= 2;
}
