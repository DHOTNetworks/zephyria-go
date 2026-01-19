// File: src/opcodes/caller.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CALLER),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    var caller_value = BigInt.init(0);
    for (0..20) |i| {
        const byte_val = evm.caller_address[i];
        const bit_pos = i * 8;
        const word_idx = bit_pos / 64;
        const bit_in_word = bit_pos % 64;
        if (word_idx < 4) {
            caller_value.data[word_idx] |= (@as(u64, byte_val) << @intCast(bit_in_word));
        }
    }
    try evm.stack.push(evm.allocator, caller_value);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // CALLER: Push caller address from JitContext
    try jit.push_virtual_memory();
    stack_top.* += 1;
    try jit.materialize_slot(@intCast(stack_top.* - 1));
    const slot = jit.get_virtual_slot(@intCast(stack_top.* - 1));
    try jit.emit_native_caller(slot.register);
}
