// File: src/opcodes/log4.zig
// LOG4 (0xa4): Emit log with 4 topics
// Stack: offset, size, topic1, topic2, topic3, topic4 ->

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;
const EthereumLog = @import("../main.zig").EthereumLog;

const LOG_BASE_GAS: u64 = 375;
const LOG_DATA_GAS: u64 = 8;
const LOG_TOPIC_GAS: u64 = 375;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.LOG4),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.call_stack.isStatic()) {
        return error.StaticCallViolation;
    }

    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;
    const topic1_big = evm.stack.pop() orelse return error.StackUnderflow;
    const topic2_big = evm.stack.pop() orelse return error.StackUnderflow;
    const topic3_big = evm.stack.pop() orelse return error.StackUnderflow;
    const topic4_big = evm.stack.pop() orelse return error.StackUnderflow;

    if (!offset_big.fitsInU64() or !size_big.fitsInU64()) {
        return error.OutOfGas;
    }
    const offset: usize = @intCast(offset_big.data[0]);
    const size: usize = @intCast(size_big.data[0]);

    const data_gas: u64 = @as(u64, size) * LOG_DATA_GAS;
    try evm.consumeGas(LOG_BASE_GAS + data_gas + LOG_TOPIC_GAS * 4);

    try evm.memory.ensureCapacity(evm.allocator, offset + size);

    var data = try evm.allocator.alloc(u8, size);
    for (0..size) |i| {
        data[i] = evm.memory.loadByte(offset + i);
    }

    var log = EthereumLog.init(evm.allocator, evm.current_address);
    try log.addTopic(evm.allocator, topic1_big.toBytes());
    try log.addTopic(evm.allocator, topic2_big.toBytes());
    try log.addTopic(evm.allocator, topic3_big.toBytes());
    try log.addTopic(evm.allocator, topic4_big.toBytes());
    try log.setData(evm.allocator, data);
    evm.allocator.free(data);

    try evm.logs.append(evm.allocator, log);
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 6) return error.StackUnderflow;
    const offset_idx = stack_top.* - 1;
    const size_idx = stack_top.* - 2;

    try jit.materialize_slot(@intCast(offset_idx));
    try jit.materialize_slot(@intCast(size_idx));
    try jit.materialize_slot(@intCast(stack_top.* - 3));
    try jit.materialize_slot(@intCast(stack_top.* - 4));
    try jit.materialize_slot(@intCast(stack_top.* - 5));
    try jit.materialize_slot(@intCast(stack_top.* - 6));

    const offset_slot = jit.get_virtual_slot(@intCast(offset_idx));
    const size_slot = jit.get_virtual_slot(@intCast(size_idx));
    const t0_slot = jit.get_virtual_slot(@intCast(stack_top.* - 3));
    const t1_slot = jit.get_virtual_slot(@intCast(stack_top.* - 4));
    const t2_slot = jit.get_virtual_slot(@intCast(stack_top.* - 5));
    const t3_slot = jit.get_virtual_slot(@intCast(stack_top.* - 6));

    try jit.emit_native_log4(offset_slot.register, size_slot.register, t0_slot.register, t1_slot.register, t2_slot.register, t3_slot.register);
    jit.pop_virtual(6);
    stack_top.* -= 6;
}
