const std = @import("std");
const EVM = @import("vm").EVM;
const BigInt = @import("vm").BigInt;

const ITERATIONS = 1000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           ZEPHYRIA NATIVE VM - PRODUCTION BENCHMARK          ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    // Simplified Arithmetic Loop for Debug: 10,000 iterations
    // Corrected Arithmetic Loop: 1,000,000 iterations
    // Debug Loop: 3 iterations
    // Isolating Hang: 10 iterations
    //    const arithmetic_bytecode = [_]u8{
    //        0x60, 0x0A, // 0-1: PUSH1 10
    //        0x5B, // 2: JUMPDEST
    //        0x60, 0x01, // 3-4: PUSH1 1
    //        0x90, // 5: SWAP1
    //        0x03, // 6: SUB
    //        0x80, // 7: DUP1
    //        0x60, 0x02, // 8-9: PUSH1 2 (loop)
    //        0x57, // 10: JUMPI
    //        0x00, // 11: STOP
    //    };

    //    run_benchmark(allocator, "Arithmetic Loop (Isolate)", &arithmetic_bytecode) catch |err| {
    //        std.debug.print("ERORR in Arithmetic Loop: {}\n", .{err});
    //        return err;
    //    };

    // Production Math Loop: Sum of first 10,000,000 numbers
    // Simulates a non-trivial Solidity loop with stack management
    const math_bytecode = [_]u8{
        0x60, 0x00, // 0-1: PUSH1 0 (result)
        0x60, 0x00, // 2-3: PUSH1 0 (i)
        0x5B, // 4: JUMPDEST
        0x80, // 5: DUP1 (i)
        0x63, 0x00, 0x98, 0x96, 0x80, // 6-10: PUSH4 10,000,000 (n)
        0x10, // 11: LT (i < n)
        0x15, // 12: ISZERO
        0x60, 0x1B, // 13-14: PUSH1 27 (exit target)
        0x57, // 15: JUMPI
        0x81, // 16: DUP2 (result)
        0x81, // 17: DUP2 (i)
        0x01, // 18: ADD (result + i)
        0x91, // 19: SWAP2 (move new result under i)
        0x50, // 20: POP (pop old result)
        0x60, 0x01, // 21-22: PUSH1 1
        0x01, // 23: ADD (i++)
        0x60, 0x04, // 24-25: PUSH1 4 (loop target)
        0x56, // 26: JUMP (to 4)
        0x5B, // 27: JUMPDEST (exit)
        0x00, // 28: STOP
    };

    run_benchmark(allocator, "Production Math (10M Iters)", &math_bytecode, 10_000_000, 16) catch |err| {
        std.debug.print("ERORR in Math Loop: {}\n", .{err});
        return err;
    };

    // Memory Hammer Benchmark: Sequential MSTORE/MLOAD (32KB) - disabled
    // const memory_hammer_bytecode = [_]u8{
    //     0x60, 0x00, // 0-1: PUSH1 0 (offset)
    //     0x61, 0x80, 0x00, // 2-4: PUSH2 32768 (limit)
    //     0x5B, // 5: JUMPDEST (loop start)
    //     0x81, // 6: DUP2 (offset)
    //     0x60, 0xAA, // 7-8: PUSH1 0xAA (value)
    //     0x52, // 9: MSTORE
    //     0x60, 0x20, // 10-11: PUSH1 32
    //     0x01, // 12: ADD (offset += 32)
    //     0x80, // 13: DUP1 (offset)
    //     0x82, // 14: DUP3 (limit)
    //     0x10, // 15: LT
    //     0x60, 0x05, // 16-17: PUSH1 5
    //     0x57, // 18: JUMPI
    //     0x00, // 19: STOP
    // };

    // Memory hammer has potential LT/MSTORE ordering issues - disabled for now
    // run_benchmark(allocator, "Production Memory Hammer (32KB)", &memory_hammer_bytecode, 1024, 11) catch |err| {
    //     std.debug.print("ERORR in Memory Hammer: {}\n", .{err});
    //     return err;
    // };
}

fn run_benchmark(allocator: std.mem.Allocator, name: []const u8, bytecode: []const u8, inner_iters: u64, ops_per_inner: u64) !void {
    const BENCH_ITERATIONS = 1;

    std.debug.print("\n┌──────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ {s:<60} │\n", .{name});
    std.debug.print("├──────────────────────────────────────────────────────────────┤\n", .{});

    var evm = try EVM.init(allocator);
    defer evm.deinit();
    evm.setGasLimit(100_000_000);
    evm.engine_type = .native_vm;
    evm.code = bytecode;
    try evm.memory.resize(allocator, 1024 * 1024); // 1MB
    try evm.stack.items.ensureTotalCapacity(allocator, 1024);

    // Warmup & JIT Compile
    var compile_timer = try std.time.Timer.start();
    const final_stack_top = try evm.native_compiler.compile_bytecode(bytecode);
    const compile_elapsed = compile_timer.read();

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < BENCH_ITERATIONS) : (i += 1) {
        // Resetting just the VM state, not JIT code
        evm.stack.items.items.len = 0;
        evm.pc = 0;
        evm.stop_execution = false;
        // In native_vm, execution is direct.
        const func: *const fn ([*]u256, *const @import("vm").jit.JitContext) callconv(.c) void = @ptrCast(@alignCast(evm.native_compiler.getFunction()));

        const ctx = @import("vm").jit.JitContext{
            .stack_base = @ptrCast(@alignCast(evm.stack.items.items.ptr)),
            .memory_ptr = evm.memory.raw_ptr,
            .memory_len = evm.memory.size(),
            .calldata_ptr = undefined,
            .calldata_len = 0,
            .returndata_ptr = undefined,
            .returndata_len = 0,
            .address = [_]u8{0} ** 20,
            ._pad1 = undefined,
            .caller = [_]u8{0} ** 20,
            ._pad2 = undefined,
            .origin = [_]u8{0} ** 20,
            ._pad3 = undefined,
            .call_value = [_]u8{0} ** 32,
            .chain_id = 1,
            .block_number = 1,
            .timestamp = 1000,
            .gas_limit = 100_000_000,
            .gas_price = 10,
            .base_fee = 10,
            .prevrandao = [_]u8{0} ** 32,
            .coinbase = [_]u8{0} ** 20,
            ._pad4 = undefined,
            .gas_remaining = 100_000_000,
            .bytecode_ptr = undefined,
            .bytecode_len = 0,
            .db = undefined,
            .evm_sload = undefined,
            .evm_sstore = undefined,
            .evm_sha3 = undefined,
            .evm_balance = undefined,
            .evm_blockhash = undefined,
            .evm_extcodesize = undefined,
            .evm_extcodehash = undefined,
            .evm_extcodecopy = undefined,
            .evm_log = undefined,
            .evm_call = undefined,
            .evm_callcode = undefined,
            .evm_delegatecall = undefined,
            .evm_staticcall = undefined,
            .evm_create = undefined,
            .evm_create2 = undefined,
            .evm_tload = undefined,
            .evm_tstore = undefined,
            .evm_mcopy = undefined,
            .evm_extend_memory = undefined,
            .is_static = false,
            .is_halt = false,
            .is_revert = false,
            ._pad_flags = undefined,
            .evm_ptr = undefined,
            ._pad_final = undefined,
        };

        func(@ptrCast(@alignCast(evm.stack.items.items.ptr)), &ctx);
        evm.stack.items.items.len = final_stack_top;
    }
    const elapsed = timer.read();

    const tps = (@as(u64, BENCH_ITERATIONS) * 1_000_000_000) / elapsed;
    const total_opcodes = @as(u64, BENCH_ITERATIONS) * inner_iters * ops_per_inner;
    const mips = (total_opcodes * 1_000_000_000) / elapsed / 1_000_000;

    std.debug.print("│  Final Stack Depth:                       {d:>1}               │\n", .{evm.stack.items.items.len});
    if (evm.stack.items.items.len > 0) {
        std.debug.print("│  Top Stack Value (LSD):      {d:>18}               │\n", .{@as(u64, @truncate(evm.stack.items.items[evm.stack.items.items.len - 1].data[0]))});
    } else {
        std.debug.print("│  Top Stack Value (LSD):      {s:>18}               │\n", .{"(empty stack)"});
    }
    std.debug.print("│  Compile Time:                     {d:>12.3} us            │\n", .{@as(f64, @floatFromInt(compile_elapsed)) / 1000.0});
    std.debug.print("│  Iterations:                        {d:>12}               │\n", .{BENCH_ITERATIONS});
    std.debug.print("│  Total Time:                   {d:>12.3} ms            │\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    std.debug.print("│  Executions per second:        {d:>12}               │\n", .{tps});
    std.debug.print("│  Estimated Performance:        {d:>12} MIPS               │\n", .{mips});
    std.debug.print("└──────────────────────────────────────────────────────────────┘\n", .{});
}

test "Production Benchmark" {
    try main();
}
