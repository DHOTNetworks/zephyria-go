// File: src/opcodes/log0.zig
// LOG0 (0xa0): Emit log with no topics
// Stack: offset, size ->
// Gas: 375 + 8*size + memory expansion

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;
const EthereumLog = @import("../main.zig").EthereumLog;

const LOG_BASE_GAS: u64 = 375;
const LOG_DATA_GAS: u64 = 8; // Per byte of data
const LOG_TOPIC_GAS: u64 = 375; // Per topic

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.LOG0),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Check if in static context
    if (evm.call_stack.isStatic()) {
        return error.StaticCallViolation;
    }

    // Pop stack arguments
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;

    // Convert to usize
    if (!offset_big.fitsInU64() or !size_big.fitsInU64()) {
        return error.OutOfGas;
    }
    const offset: usize = @intCast(offset_big.data[0]);
    const size: usize = @intCast(size_big.data[0]);

    // Calculate gas cost
    const data_gas: u64 = @as(u64, size) * LOG_DATA_GAS;
    try evm.consumeGas(LOG_BASE_GAS + data_gas);

    // Ensure memory capacity
    try evm.memory.ensureCapacity(evm.allocator, offset + size);

    // Read data from memory
    var data = try evm.allocator.alloc(u8, size);
    for (0..size) |i| {
        data[i] = evm.memory.loadByte(offset + i);
    }

    // Create log entry
    var log = EthereumLog.init(evm.allocator, evm.current_address);
    try log.setData(evm.allocator, data);
    evm.allocator.free(data);

    // Add to logs
    try evm.logs.append(evm.allocator, log);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const offset_idx = stack_top.* - 1;
    const size_idx = stack_top.* - 2;

    try jit.materialize_slot(@intCast(offset_idx));
    try jit.materialize_slot(@intCast(size_idx));

    const offset_slot = jit.get_virtual_slot(@intCast(offset_idx));
    const size_slot = jit.get_virtual_slot(@intCast(size_idx));

    try jit.emit_native_log0(offset_slot.register, size_slot.register);
    jit.pop_virtual(2);
    stack_top.* -= 2;
}
