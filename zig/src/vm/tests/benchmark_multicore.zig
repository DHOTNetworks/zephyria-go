const std = @import("std");
const EVM = @import("vm").EVM;
const BigInt = @import("vm").BigInt;

const TOTAL_ITERATIONS = 10_000_000;
const THREAD_COUNT = 2; // User requested 2 cores

// Context for each thread
const ThreadContext = struct {
    id: usize,
    allocator: std.mem.Allocator,
    func: *const fn ([*]u256, *const @import("vm").jit.JitContext) callconv(.c) void,
    iterations: u64,
    elapsed_ns: u64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           ZEPHYRIA NATIVE VM - MULTICORE BENCHMARK           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    // Production Math Loop: Sum of first 10,000,000 numbers
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

    // 1. Compile Code (Main Thread)
    std.debug.print("Compiling bytecode... ", .{});
    var evm_main = try EVM.init(allocator);
    defer evm_main.deinit();
    evm_main.engine_type = .native_vm;
    _ = try evm_main.native_compiler.compile_bytecode(&math_bytecode);
    const func_ptr: *const fn ([*]u256, *const @import("vm").jit.JitContext) callconv(.c) void = @ptrCast(@alignCast(evm_main.native_compiler.getFunction()));
    std.debug.print("Done.\n", .{});

    // 2. Prepare Threads
    var threads: [THREAD_COUNT]std.Thread = undefined;
    var contexts: [THREAD_COUNT]ThreadContext = undefined;

    // Distribute work? Or duplicate work?
    // "Performance on 2 cores" usually means throughput test.
    // So run FULL workload on EACH core in parallel.
    // Ops = 2 * Ops.

    std.debug.print("Spawning {} threads ({} iterations each)...\n", .{ THREAD_COUNT, TOTAL_ITERATIONS });
    var start_time = try std.time.Timer.start();

    var i: usize = 0;
    while (i < THREAD_COUNT) : (i += 1) {
        contexts[i] = ThreadContext{
            .id = i,
            .allocator = allocator,
            .func = func_ptr,
            // Run bytecode ONCE per thread (it has internal loop of 10M)
            .iterations = 1,
            .elapsed_ns = 0,
        };
        threads[i] = try std.Thread.spawn(.{}, thread_worker, .{&contexts[i]});
    }

    // 3. Join Threads
    i = 0;
    while (i < THREAD_COUNT) : (i += 1) {
        threads[i].join();
    }

    const total_elapsed = start_time.read();

    // 4. Report
    std.debug.print("\n┌──────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ {s:<60} │\n", .{"Multicore Results (2 Cores)"});
    std.debug.print("├──────────────────────────────────────────────────────────────┤\n", .{});

    const ops_per_run = 10_000_000 * 16; // 10M iters * 16 instructions.

    var total_tps: u64 = 0;

    i = 0;
    while (i < THREAD_COUNT) : (i += 1) {
        const ctx = &contexts[i];
        const tps = (@as(u64, 1) * 1_000_000_000) / ctx.elapsed_ns; // Runs per second
        const mips = (1 * ops_per_run * 1_000_000_000) / ctx.elapsed_ns / 1_000_000;

        std.debug.print("│ Core {}: {d:>10.3} ms | {d:>8} TPS | {d:>8} MIPS           │\n", .{ ctx.id, @as(f64, @floatFromInt(ctx.elapsed_ns)) / 1_000_000.0, tps, mips });
        total_tps += tps;
    }

    // Combined
    const combined_mips = (2 * ops_per_run * 1_000_000_000) / total_elapsed / 1_000_000;
    std.debug.print("├──────────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ Total Time: {d:>10.3} ms                                  │\n", .{@as(f64, @floatFromInt(total_elapsed)) / 1_000_000.0});
    std.debug.print("│ Combined MIPS: {d:>10}                                    │\n", .{combined_mips});
    std.debug.print("└──────────────────────────────────────────────────────────────┘\n", .{});
}

fn thread_worker(ctx: *ThreadContext) void {
    var timer = std.time.Timer.start() catch return;

    // Each thread needs its OWN EVM environment (Stack/Memory)
    var evm = EVM.init(ctx.allocator) catch return;
    defer evm.deinit();

    evm.memory.resize(ctx.allocator, 1024 * 1024) catch return;
    evm.stack.items.ensureTotalCapacity(ctx.allocator, 1024) catch return;

    const jit_ctx = @import("vm").jit.JitContext{
        .stack_base = @ptrCast(@alignCast(evm.stack.items.items.ptr)),
        .memory_ptr = evm.memory.raw_ptr,
        .memory_len = evm.memory.size(),
        // ... (Zero initialization for others)
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

    var i: u64 = 0;
    while (i < ctx.iterations) : (i += 1) {
        ctx.func(@ptrCast(@alignCast(evm.stack.items.items.ptr)), &jit_ctx);
        evm.stack.items.items.len = 0; // Reset stack
    }

    ctx.elapsed_ns = timer.read();
}
