// File: src/opcodes/mcopy.zig
// MCOPY (0x5e): Memory copy
// Stack: destOffset, offset, size -> []
// EIP-5656: MCOPY instruction

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.MCOPY),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    const dest_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;

    if (!dest_offset_big.fitsInU64() or !offset_big.fitsInU64() or !size_big.fitsInU64()) {
        return error.OutOfMemory; // Simplified error for massive offsets
    }

    const dest_offset: usize = @intCast(dest_offset_big.data[0]);
    const offset: usize = @intCast(offset_big.data[0]);
    const size: usize = @intCast(size_big.data[0]);

    if (size == 0) return;

    // Calculate dynamic gas: 3 words * ceil(size / 32)
    const words = (size + 31) / 32;
    const copy_gas = 3 * words;
    try evm.consumeGas(copy_gas);

    // Expand memory for both source and destination
    // EIP-5656 says "The cost of memory expansion is charged for both the source and the specific destination"
    const max_offset = @max(dest_offset + size, offset + size);
    try evm.memory.ensureCapacity(evm.allocator, max_offset);

    // Perform copy using memmove semantics (handles overlap)
    // evm.memory.copy handles overlap if implemented correctly, but let's check memory.zig
    // If not, we copy to buffer.

    // We can use std.mem.copyForwards or copyBackwards, but safest is to use a temp buffer or logic wrapper if we don't have direct access
    // The safest way with raw pointers (if memory.zig exposes slices):
    const mem_slice = evm.memory.getData();
    if (mem_slice.len < max_offset) return error.MemoryExpansionFailed;

    const src = mem_slice[offset .. offset + size];
    const dst = mem_slice[dest_offset .. dest_offset + size];

    // Handle overlap
    if (dest_offset > offset and dest_offset < offset + size) {
        std.mem.copyBackwards(u8, dst, src);
    } else {
        std.mem.copyForwards(u8, dst, src);
    }
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // MCOPY: Stack order pops destOffset first (top), then offset(src), then size.
    // stack_top-1 = top = dst
    // stack_top-2 = src
    // stack_top-3 = size
    if (stack_top.* < 3) return error.StackUnderflow;
    const dst_sidx = stack_top.* - 1;
    const src_sidx = stack_top.* - 2;
    const size_sidx = stack_top.* - 3;

    try jit.materialize_slot(@intCast(dst_sidx));
    try jit.materialize_slot(@intCast(src_sidx));
    try jit.materialize_slot(@intCast(size_sidx));

    const dst_slot = jit.get_virtual_slot(@intCast(dst_sidx));
    const src_slot = jit.get_virtual_slot(@intCast(src_sidx));
    const size_slot = jit.get_virtual_slot(@intCast(size_sidx));

    const dst_reg = switch (dst_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };
    const src_reg = switch (src_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };
    const size_reg = switch (size_slot) {
        .register => |r| r,
        else => return error.InvalidStackState,
    };

    try jit.emit_native_mcopy(dst_reg, src_reg, size_reg);

    jit.pop_virtual(3);
    stack_top.* -= 3;
}
