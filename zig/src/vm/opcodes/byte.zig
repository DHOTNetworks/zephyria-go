// File: src/opcodes/byte.zig
// BYTE (0x1a): Extract a byte from a 256-bit word
// Stack: i, x -> byte
// Returns the i-th byte of x (0 = most significant, 31 = least significant)
// Returns 0 if i >= 32

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.BYTE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const i = evm.stack.pop() orelse return error.StackUnderflow;
    const x = evm.stack.pop() orelse return error.StackUnderflow;

    // Use BigInt's getByte method
    const result = x.getByte(i);
    try evm.stack.push(evm.allocator, result);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const i_idx = stack_top.* - 1; // byte index (TOS)
    const x_idx = stack_top.* - 2; // value

    const v_i = jit.get_virtual_slot(@intCast(i_idx));
    const v_x = jit.get_virtual_slot(@intCast(x_idx));

    // Constant folding
    if (v_i == .constant and v_x == .constant) {
        const i = v_i.constant;
        const x = v_x.constant;
        var result: u256 = 0;
        if (i < 32) {
            // Byte 0 is MSB, byte 31 is LSB
            const shift = @as(u8, @intCast((31 - i) * 8));
            result = (x >> shift) & 0xFF;
        }
        jit.pop_virtual(2);
        try jit.push_virtual_constant(result);
        stack_top.* -= 1;
        return;
    }

    // Dynamic case: emit native code
    try jit.materialize_slot(@intCast(i_idx));
    try jit.materialize_slot(@intCast(x_idx));

    const i_slot = jit.get_virtual_slot(@intCast(i_idx));
    const x_slot = jit.get_virtual_slot(@intCast(x_idx));

    try jit.emit_native_byte(x_slot.register, i_slot.register, x_slot.register);
    jit.pop_virtual(1);
    stack_top.* -= 1;
}
