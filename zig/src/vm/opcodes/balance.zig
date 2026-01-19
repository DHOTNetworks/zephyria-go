// File: src/opcodes/balance.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.BALANCE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Pop address from stack
    if (evm.stack.pop()) |address_bigint| {
        // Convert BigInt to 20-byte address
        var address: [20]u8 = [_]u8{0} ** 20;

        // Extract address from BigInt (reverse the encoding)
        for (0..20) |i| {
            const bit_pos = i * 8;
            const word_idx = bit_pos / 64;
            const bit_in_word = bit_pos % 64;

            if (word_idx < 4) {
                const word_val = address_bigint.data[word_idx];
                address[i] = @intCast((word_val >> @intCast(bit_in_word)) & 0xFF);
            }
        }

        // Look up account balance
        if (evm.accounts.get(address)) |account| {
            try evm.stack.push(evm.allocator, account.balance);
        } else {
            // Account doesn't exist, balance is 0
            try evm.stack.push(evm.allocator, BigInt.init(0));
        }
    } else {
        return error.StackUnderflow;
    }
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 1) return error.StackUnderflow;
    // BALANCE: Pop address, push balance
    const addr_idx = stack_top.* - 1;
    try jit.materialize_slot(addr_idx);
    const addr_slot = jit.get_virtual_slot(@intCast(addr_idx)); // Address is top

    // Result reuses the slot? Or new slot?
    // BALANCE pops 1, pushes 1.
    // Address is consumed. Result overwrites it.
    // Use addr_slot for both if possible? No, input and output registers.
    // get_virtual_slot gives register of input.
    // Write result to SAME register?
    // emit_native_balance(dst, addr).
    // If dst == addr, it's fine (addr used then overwritten).
    try jit.emit_native_balance(addr_slot.register, addr_slot.register);
    // Stack top remains same.
    // Stack depth unchanged (1 in, 1 out)
}
