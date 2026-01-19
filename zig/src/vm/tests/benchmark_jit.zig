// File: src/vm/tests/benchmark_jit.zig
// Benchmark for Native VM execution
const std = @import("std");
const EVM = @import("vm").EVM;
const BigInt = @import("vm").BigInt;

const ITERATIONS = 10;

fn run_native_benchmark(bytecode: []const u8) !u64 {
    const allocator = std.testing.allocator;

    var total_time: u64 = 0;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        // Fresh EVM for each iteration
        var evm = try EVM.init(allocator);
        defer evm.deinit();

        evm.setGasLimit(1_000_000);
        evm.engine_type = .native_vm;
        evm.code = bytecode;

        var timer = try std.time.Timer.start();
        try evm.execute();
        total_time += timer.read();

        // Verify result
        const result = evm.stack.pop() orelse return error.EmptyStack;
        _ = result;
    }

    return total_time / ITERATIONS;
}

test "Native VM: Simple Arithmetic (PUSH+ADD)" {
    // PUSH1 5, PUSH1 10, ADD = 15
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x0a, 0x01 };
    const avg_ns = try run_native_benchmark(&bytecode);
    std.debug.print("\n=== Native VM: Simple Arithmetic ===\n", .{});
    std.debug.print("Average: {d} ns/iter\n", .{avg_ns});
}

test "Native VM: Complex Arithmetic" {
    // PUSH1 10, PUSH1 5, MUL, PUSH1 25, ADD, PUSH1 5, DIV
    const bytecode = [_]u8{
        0x60, 0x0a, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x02, // MUL
        0x60, 0x19, // PUSH1 25
        0x01, // ADD
        0x60, 0x05, // PUSH1 5
        0x04, // DIV
    };
    const avg_ns = try run_native_benchmark(&bytecode);
    std.debug.print("\n=== Native VM: Complex Arithmetic ===\n", .{});
    std.debug.print("Average: {d} ns/iter\n", .{avg_ns});
}

test "Native VM: Bitwise AND" {
    const bytecode = [_]u8{
        0x60, 0xff, // PUSH1 255
        0x60, 0x0f, // PUSH1 15
        0x16, // AND
    };
    const avg_ns = try run_native_benchmark(&bytecode);
    std.debug.print("\n=== Native VM: Bitwise AND ===\n", .{});
    std.debug.print("Average: {d} ns/iter\n", .{avg_ns});
}

test "Native VM: Comparison LT" {
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10, // LT
    };
    const avg_ns = try run_native_benchmark(&bytecode);
    std.debug.print("\n=== Native VM: Comparison LT ===\n", .{});
    std.debug.print("Average: {d} ns/iter\n", .{avg_ns});
}
