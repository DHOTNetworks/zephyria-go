// File: src/vm/joyboy/registers.zig
const std = @import("std");

pub const NUM_BANKS = 4;
// Bank 0: x4-x7 (Volatile)
// Bank 1: x11-x14 (Volatile)
// Bank 2: x21-x24 (Callee-saved)
// Bank 3: x25-x28 (Callee-saved)

// Scratch used: x0-x3 (Args/Ret), x8 (Indirect Ret?), x9-x10 (Temp), x15 (Temp?), x16-x17 (IP), x18 (Reset), x19-x20 (Fixed)

pub const RegisterBankState = struct {
    is_free: bool,
    stack_idx: ?usize, // Which EVM stack slot this bank holds
    locked: bool = false, // If true, cannot be spilled (used by current instruction)
};

pub fn get_bank_regs(bank_idx: u8) [4]u8 {
    return switch (bank_idx) {
        0 => .{ 4, 5, 6, 7 },
        1 => .{ 8, 9, 10, 11 },
        2 => .{ 12, 13, 14, 15 },
        3 => .{ 21, 22, 23, 24 },
        4 => .{ 25, 26, 27, 28 }, // Potentially unused if NUM_BANKS=4
        else => unreachable,
    };
}
