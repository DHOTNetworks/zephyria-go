// File: src/opcodes/return.zig
// RETURN (0xf3): Halt execution and return output data
// Stack: offset, size -> (none)
// Copies 'size' bytes from memory at 'offset' to return data and halts execution

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.RETURN),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;

    // Convert to usize with bounds checking
    if (!size_big.fitsInU64()) {
        evm.stop_execution = true;
        return;
    }
    const size: usize = @intCast(size_big.data[0]);

    if (!offset_big.fitsInU64()) {
        evm.stop_execution = true;
        return;
    }
    const offset: usize = @intCast(offset_big.data[0]);

    // Allocate return data buffer
    var return_buffer: []u8 = &[_]u8{};
    if (size > 0) {
        return_buffer = try evm.allocator.alloc(u8, size);
        for (0..size) |i| {
            return_buffer[i] = evm.memory.loadByte(offset + i);
        }
    }
    // Ownership transferred to exitCall/EVM

    // Exit call with success
    try evm.exitCall(.{ .success = true, .data = return_buffer });
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    if (stack_top.* < 2) return error.StackUnderflow;
    const offset_idx = stack_top.* - 1; // Top is Offset
    const size_idx = stack_top.* - 2; // Top-1 is Size

    try jit.materialize_slot(@intCast(size_idx));
    try jit.materialize_slot(@intCast(offset_idx));

    const s_slot = jit.get_virtual_slot(@intCast(size_idx));
    const o_slot = jit.get_virtual_slot(@intCast(offset_idx));

    if (s_slot != .register or o_slot != .register) {
        return error.JitRegisterAllocationFailed;
    }

    try jit.emit_native_return(o_slot.register, s_slot.register);
    // Stack is effectively cleared/ignored as we halt?
    // Opcode impl pops 2.
    jit.pop_virtual(2);
    stack_top.* -= 2;
}
