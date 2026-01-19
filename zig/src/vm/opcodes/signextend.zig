// File: src/opcodes/signextend.zig
// SIGNEXTEND (0x0b): Sign extend a value
// Stack: b, x -> result
// Sign-extends x from (b+1) bytes to 32 bytes
// The sign bit is at position (b+1)*8-1 counting from LSB

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.SIGNEXTEND),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const b = evm.stack.pop() orelse return error.StackUnderflow;
    const x = evm.stack.pop() orelse return error.StackUnderflow;

    // Use BigInt's signExtend method
    const result = x.signExtend(b);
    try evm.stack.push(evm.allocator, result);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const b_idx = stack_top.* - 1; // byte position (0-30)
    const x_idx = stack_top.* - 2; // value

    const v_b = jit.get_virtual_slot(@intCast(b_idx));
    const v_x = jit.get_virtual_slot(@intCast(x_idx));

    // Constant folding
    if (v_b == .constant and v_x == .constant) {
        const b = v_b.constant;
        const x = v_x.constant;
        var result = x;

        if (b < 31) {
            const bit_pos = @as(u8, @intCast(b * 8 + 7));
            const sign_bit = (x >> bit_pos) & 1;
            if (sign_bit == 1) {
                // Extend with 1s
                const mask = (@as(u256, 1) << @as(u8, @intCast(bit_pos + 1))) - 1;
                result = x | ~mask;
            } else {
                // Extend with 0s (mask off upper bits)
                const mask = (@as(u256, 1) << @as(u8, @intCast(bit_pos + 1))) - 1;
                result = x & mask;
            }
        }

        jit.pop_virtual(2);
        try jit.push_virtual_constant(result);
        stack_top.* -= 1;
        return;
    }

    // Dynamic case
    try jit.materialize_slot(@intCast(b_idx));
    try jit.materialize_slot(@intCast(x_idx));

    const b_slot = jit.get_virtual_slot(@intCast(b_idx));
    const x_slot = jit.get_virtual_slot(@intCast(x_idx));

    try jit.emit_native_signextend(x_slot.register, b_slot.register, x_slot.register);
    jit.pop_virtual(1);
    stack_top.* -= 1;
}
