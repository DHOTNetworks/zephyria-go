// File: src/opcodes/callcode.zig
// CALLCODE (0xf2): Call with another contract's code but own storage
// Stack: gas, addr, value, argsOffset, argsSize, retOffset, retSize -> success
// Like CALL but executes target's code in caller's context

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;

// Gas costs
const CALL_BASE_GAS: u64 = 100;
const CALL_VALUE_TRANSFER_GAS: u64 = 9000;
const CALL_STIPEND: u64 = 2300;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CALLCODE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Pop stack arguments
    const gas_big = evm.stack.pop() orelse return error.StackUnderflow;
    const addr_big = evm.stack.pop() orelse return error.StackUnderflow;
    const value_big = evm.stack.pop() orelse return error.StackUnderflow;
    const args_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const args_size_big = evm.stack.pop() orelse return error.StackUnderflow;
    const ret_offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const ret_size_big = evm.stack.pop() orelse return error.StackUnderflow;

    // Extract address (last 20 bytes)
    const addr_bytes = addr_big.toBytes();
    var target_addr: [20]u8 = undefined;
    @memcpy(&target_addr, addr_bytes[12..32]);

    // Convert sizes
    if (!args_offset_big.fitsInU64() or !args_size_big.fitsInU64() or
        !ret_offset_big.fitsInU64() or !ret_size_big.fitsInU64())
    {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }
    const args_offset: usize = @intCast(args_offset_big.data[0]);
    const args_size: usize = @intCast(args_size_big.data[0]);
    const ret_offset: usize = @intCast(ret_offset_big.data[0]);
    const ret_size: usize = @intCast(ret_size_big.data[0]);

    // Calculate gas cost
    var extra_gas: u64 = CALL_BASE_GAS;
    if (!value_big.isZero()) {
        extra_gas += CALL_VALUE_TRANSFER_GAS;
    }
    try evm.consumeGas(extra_gas);

    // Check call depth
    if (evm.call_stack.depth() >= 1024) {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }

    // Get caller account (we're using caller's storage)
    const caller_ptr = evm.accounts.getPtr(evm.current_address);
    if (caller_ptr == null) {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }
    const caller = caller_ptr.?;

    // Check balance for value transfer
    if (caller.balance.lt(value_big)) {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }

    // Read calldata from memory
    try evm.memory.ensureCapacity(evm.allocator, args_offset + args_size);

    // Get target's code
    const target_code = if (evm.accounts.get(target_addr)) |acc| acc.code else &[_]u8{};

    // If no code, call succeeds with no execution
    if (target_code.len == 0) {
        try evm.memory.ensureCapacity(evm.allocator, ret_offset + ret_size);
        if (evm.return_data.len > 0) {
            evm.allocator.free(evm.return_data);
        }
        evm.return_data = &[_]u8{};
        try evm.stack.push(evm.allocator, BigInt.init(1));
        return;
    }

    // Calculate gas to pass
    const gas_requested: u64 = if (gas_big.fitsInU64()) gas_big.data[0] else std.math.maxInt(u64);
    const gas_available = evm.gas - (evm.gas / 64);
    const call_gas = @min(gas_requested, gas_available);
    _ = call_gas;

    // In a full implementation:
    // - Execute target's code in caller's context
    // - msg.sender = caller, storage = caller's storage
    // - Value transfer is to self (no actual transfer)

    try evm.memory.ensureCapacity(evm.allocator, ret_offset + ret_size);
    if (evm.return_data.len > 0) {
        evm.allocator.free(evm.return_data);
    }
    evm.return_data = &[_]u8{};

    try evm.stack.push(evm.allocator, BigInt.init(1));
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // CALLCODE: gas, addr, value, argsOffset, argsSize, retOffset, retSize -> success
    if (stack_top.* < 7) return error.StackUnderflow;

    const gas_idx = stack_top.* - 1;
    const addr_idx = stack_top.* - 2;
    const val_idx = stack_top.* - 3;
    const af_idx = stack_top.* - 4;
    const al_idx = stack_top.* - 5;
    const rf_idx = stack_top.* - 6;
    const rl_idx = stack_top.* - 7;

    try jit.materialize_slot(gas_idx);
    try jit.materialize_slot(addr_idx);
    try jit.materialize_slot(val_idx);
    try jit.materialize_slot(af_idx);
    try jit.materialize_slot(al_idx);
    try jit.materialize_slot(rf_idx);
    try jit.materialize_slot(rl_idx);

    const gas_slot = jit.get_virtual_slot(@intCast(gas_idx));
    const addr_slot = jit.get_virtual_slot(@intCast(addr_idx));
    const val_slot = jit.get_virtual_slot(@intCast(val_idx));
    const af_slot = jit.get_virtual_slot(@intCast(af_idx));
    const al_slot = jit.get_virtual_slot(@intCast(al_idx));
    const rf_slot = jit.get_virtual_slot(@intCast(rf_idx));
    const rl_slot = jit.get_virtual_slot(@intCast(rl_idx));

    try jit.emit_native_callcode(gas_slot.register, addr_slot.register, val_slot.register, af_slot.register, al_slot.register, rf_slot.register, rl_slot.register, rl_slot.register);

    jit.pop_virtual(6);
    stack_top.* -= 6;
}
