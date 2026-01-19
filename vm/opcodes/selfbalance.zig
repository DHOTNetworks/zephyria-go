// File: src/opcodes/selfbalance.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.SELFBALANCE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Push the balance of the current contract address onto the stack
    if (evm.accounts.get(evm.current_address)) |account| {
        try evm.stack.push(evm.allocator, account.balance);
    } else {
        // Current contract doesn't exist, balance is 0
        try evm.stack.push(evm.allocator, BigInt.init(0));
    }
}
pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // SELFBALANCE: Read balance of current address from context
    // SELFBALANCE: Push balance of current contract
    try jit.push_virtual_memory();
    stack_top.* += 1;
    try jit.materialize_slot(@intCast(stack_top.* - 1));
    const slot = jit.get_virtual_slot(@intCast(stack_top.* - 1));
    try jit.emit_native_selfbalance(slot.register);
}
