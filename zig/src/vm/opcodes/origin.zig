// File: src/opcodes/origin.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.ORIGIN),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    var origin_value = BigInt.init(0);
    for (0..20) |i| {
        const byte_val = evm.origin_address[i];
        const bit_pos = i * 8;
        const word_idx = bit_pos / 64;
        const bit_in_word = bit_pos % 64;
        if (word_idx < 4) {
            origin_value.data[word_idx] |= (@as(u64, byte_val) << @intCast(bit_in_word));
        }
    }
    try evm.stack.push(evm.allocator, origin_value);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    const stencils = @import("stencils");
    try jit.emit_stencil(stencils.Origin, &.{
        .{ .symbol = "_HOLE_DST", .value = stack_top.* },
    });
    stack_top.* += 1;
}
