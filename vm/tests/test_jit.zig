const std = @import("std");
const vm = @import("vm");
const JitCompiler = vm.jit.JitCompiler;
const JitContext = vm.jit.JitContext;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Zephyria JIT Verification Suite ===\n", .{});

    try testArithmeticLoop(allocator);
    // Memory ops enabled
    try testMemoryOps(allocator);
    try testCalldataOps(allocator);
    try testResourceIntensive(allocator);

    std.debug.print("\n=== All JIT Verification Tests Passed! ===\n", .{});
}

fn testArithmeticLoop(allocator: std.mem.Allocator) !void {
    std.debug.print("\n[Test] Arithmetic Loop (10 * 5 = 50)...\n", .{});

    var jit_comp = try JitCompiler.init(allocator, 16384);
    defer jit_comp.deinit();

    // Bytecode for simple loop:
    // 0: PUSH1 10 (count)
    // 2: JUMPDEST (PC=2)
    // 3: PUSH1 1
    // 5: SWAP1
    // 6: SUB      (count - 1)
    // 7: DUP1     (new count for JUMPI condition)
    // 8: PUSH1 2  (jump target PC=2)
    // 10: JUMPI

    const bytecode = [_]u8{
        0x60, 0x0a, // PUSH1 10
        0x5b, // JUMPDEST (PC=2)
        0x60, 0x01, // PUSH1 1
        0x03, // SUB      -> [count - 1]
        0x80, // DUP1     -> [count-1, count-1]
        0x60, 0x02, // PUSH1 2 (target PC=2)
        0x57, // JUMPI
    };

    try jit_comp.compile_bytecode(&bytecode);
    std.debug.print("[Test] Compiled Code Length: {d} bytes\n", .{jit_comp.current_offset});

    var stack: [1024]u256 align(16) = [_]u256{0} ** 1024;
    var ctx = JitContext{
        .stack_base = @ptrCast(&stack),
        .memory_ptr = undefined,
        .memory_len = 0,
        .calldata_ptr = undefined,
        .calldata_len = 0,
        .returndata_ptr = undefined,
        .returndata_len = 0,
        .address = [_]u8{0} ** 20,
        ._pad1 = [_]u8{0} ** 4,
        .caller = [_]u8{0} ** 20,
        ._pad2 = [_]u8{0} ** 4,
        .origin = [_]u8{0} ** 20,
        ._pad3 = [_]u8{0} ** 4,
        .call_value = [_]u8{0} ** 32,
        .chain_id = 0,
        .block_number = 0,
        .timestamp = 0,
        .gas_limit = 0,
        .gas_price = 0,
        .base_fee = 0,
        .prevrandao = [_]u8{0} ** 32,
        .coinbase = [_]u8{0} ** 20,
        ._pad4 = [_]u8{0} ** 4,
        .gas_remaining = 0,
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
        ._pad_flags = [_]u8{0} ** 5,
        .evm_ptr = undefined,
        ._pad_final = [_]u8{0} ** 8,
    };

    const func_ptr = jit_comp.getFunction();
    const func: *const fn ([*]u256, *const JitContext) callconv(.c) void = @ptrCast(@alignCast(func_ptr));
    func(@ptrCast(&stack), &ctx);

    std.debug.print("Result: stack[0]={d}\n", .{stack[0]});
    try std.testing.expectEqual(@as(u256, 0), stack[0]);
    std.debug.print("[PASS]\n", .{});
}

fn testMemoryOps(allocator: std.mem.Allocator) !void {
    std.debug.print("\n[Test] Memory Operations (MSTORE/MLOAD)...\n", .{});

    var jit_comp = try JitCompiler.init(allocator, 16384);
    defer jit_comp.deinit();

    // PUSH32 0xFF...FF, PUSH1 0, MSTORE, PUSH1 0, MLOAD
    const bytecode = [_]u8{
        0x7f, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (offset 0, val 0xFF...FF)
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD (offset 0)
    };

    try jit_comp.compile_bytecode(&bytecode);

    const stack = try allocator.alloc(u256, 1024);
    defer allocator.free(stack);
    @memset(stack, 0);

    // Use VM Memory (Soft-MMU)
    var memory = try vm.Memory.init(allocator);
    defer memory.deinit(allocator);
    try memory.ensureCapacity(allocator, 128);

    var ctx = JitContext{
        .stack_base = @ptrCast(stack.ptr),
        .memory_ptr = memory.raw_ptr,
        .memory_len = memory.committed_len,
        .calldata_ptr = undefined,
        .calldata_len = 0,
        .returndata_ptr = undefined,
        .returndata_len = 0,
        .address = [_]u8{0} ** 20,
        ._pad1 = [_]u8{0} ** 4,
        .caller = [_]u8{0} ** 20,
        ._pad2 = [_]u8{0} ** 4,
        .origin = [_]u8{0} ** 20,
        ._pad3 = [_]u8{0} ** 4,
        .call_value = [_]u8{0} ** 32,
        .chain_id = 0,
        .block_number = 0,
        .timestamp = 0,
        .gas_limit = 0,
        .gas_price = 0,
        .base_fee = 0,
        .prevrandao = [_]u8{0} ** 32,
        .coinbase = [_]u8{0} ** 20,
        ._pad4 = [_]u8{0} ** 4,
        .gas_remaining = 0,
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
        ._pad_flags = [_]u8{0} ** 5,
        .evm_ptr = undefined,
        ._pad_final = [_]u8{0} ** 8,
    };

    const func_ptr = jit_comp.getFunction();
    const func: *const fn ([*]u256, *const JitContext) callconv(.c) void = @ptrCast(@alignCast(func_ptr));
    func(@ptrCast(stack.ptr), &ctx);

    const mem_slice = memory.getData();
    std.debug.print("Memory[0..32]: ", .{});
    for (mem_slice[0..32]) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n", .{});

    for (mem_slice[0..32]) |b| try std.testing.expectEqual(@as(u8, 0xFF), b);
    try std.testing.expectEqual(@as(u256, ~@as(u256, 0)), stack[0]);
    std.debug.print("[PASS]\n", .{});
}

fn testCalldataOps(allocator: std.mem.Allocator) !void {
    std.debug.print("\n[Test] Calldata Operations (CALLDATALOAD)...\n", .{});

    var jit_comp = try JitCompiler.init(allocator, 16384);
    defer jit_comp.deinit();

    // PUSH1 0, CALLDATALOAD
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
    };

    try jit_comp.compile_bytecode(&bytecode);

    var stack: [1024]u256 align(16) = [_]u256{0} ** 1024;
    var calldata = [_]u8{0xAA} ** 32;

    var ctx = JitContext{
        .stack_base = @ptrCast(&stack),
        .memory_ptr = undefined,
        .memory_len = 0,
        .calldata_ptr = @ptrCast(&calldata),
        .calldata_len = calldata.len,
        .returndata_ptr = undefined,
        .returndata_len = 0,
        .address = [_]u8{0} ** 20,
        ._pad1 = [_]u8{0} ** 4,
        .caller = [_]u8{0} ** 20,
        ._pad2 = [_]u8{0} ** 4,
        .origin = [_]u8{0} ** 20,
        ._pad3 = [_]u8{0} ** 4,
        .call_value = [_]u8{0} ** 32,
        .chain_id = 0,
        .block_number = 0,
        .timestamp = 0,
        .gas_limit = 0,
        .gas_price = 0,
        .base_fee = 0,
        .prevrandao = [_]u8{0} ** 32,
        .coinbase = [_]u8{0} ** 20,
        ._pad4 = [_]u8{0} ** 4,
        .gas_remaining = 0,
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
        ._pad_flags = [_]u8{0} ** 5,
        .evm_ptr = undefined,
        ._pad_final = [_]u8{0} ** 8,
    };

    const func_ptr = jit_comp.getFunction();
    const func: *const fn ([*]u256, *const JitContext) callconv(.c) void = @ptrCast(@alignCast(func_ptr));
    func(@ptrCast(&stack), &ctx);

    std.debug.print("Stack[0]: {x}\n", .{stack[0]});
    // CALLDATALOAD packs 32 bytes.
    var expected: u256 = 0;
    for (calldata) |b| expected = (expected << 8) | b;

    try std.testing.expectEqual(expected, stack[0]);
    std.debug.print("[PASS]\n", .{});
}

fn testResourceIntensive(allocator: std.mem.Allocator) !void {
    std.debug.print("\n[Test] Arithmetic Stress (10000 operations)...\n", .{});

    var jit_comp = try JitCompiler.init(allocator, 4 * 1024 * 1024); // 4MB for stress test
    defer jit_comp.deinit();

    // Generate bytecode: 10000 sequential ADD operations
    // PUSH1 1, PUSH1 1, ADD, PUSH1 1, ADD, ...
    var bytecode_list = std.ArrayListUnmanaged(u8){};
    defer bytecode_list.deinit(allocator);

    try bytecode_list.appendSlice(allocator, &[_]u8{ 0x60, 0x01 }); // PUSH1 1
    for (0..9999) |_| {
        try bytecode_list.appendSlice(allocator, &[_]u8{ 0x60, 0x01, 0x01 }); // PUSH1 1, ADD
    }

    const bytecode = bytecode_list.items;
    std.debug.print("Bytecode size: {d} bytes\n", .{bytecode.len});

    var timer = try std.time.Timer.start();
    try jit_comp.compile_bytecode(bytecode);
    const compile_time = timer.read();

    const stack = try allocator.alloc(u256, 1024);
    defer allocator.free(stack);
    @memset(stack, 0);

    var ctx = JitContext{
        .stack_base = @ptrCast(stack.ptr),
        .memory_ptr = undefined,
        .memory_len = 0,
        .calldata_ptr = undefined,
        .calldata_len = 0,
        .returndata_ptr = undefined,
        .returndata_len = 0,
        .address = [_]u8{0} ** 20,
        ._pad1 = [_]u8{0} ** 4,
        .caller = [_]u8{0} ** 20,
        ._pad2 = [_]u8{0} ** 4,
        .origin = [_]u8{0} ** 20,
        ._pad3 = [_]u8{0} ** 4,
        .call_value = [_]u8{0} ** 32,
        .chain_id = 0,
        .block_number = 0,
        .timestamp = 0,
        .gas_limit = 0,
        .gas_price = 0,
        .base_fee = 0,
        .prevrandao = [_]u8{0} ** 32,
        .coinbase = [_]u8{0} ** 20,
        ._pad4 = [_]u8{0} ** 4,
        .gas_remaining = 0,
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
        ._pad_flags = [_]u8{0} ** 5,
        .evm_ptr = undefined,
        ._pad_final = [_]u8{0} ** 8,
    };

    const func_ptr = jit_comp.getFunction();
    const func: *const fn ([*]u256, *const JitContext) callconv(.c) void = @ptrCast(@alignCast(func_ptr));

    timer.reset();
    func(@ptrCast(stack.ptr), &ctx);
    const exec_time = timer.read();

    std.debug.print("Compilation Time: {d:.3} ms ({d} ns)\n", .{ @as(f64, @floatFromInt(compile_time)) / 1_000_000.0, compile_time });
    std.debug.print("Execution Time (10000 ops): {d:.3} us ({d} ns)\n", .{ @as(f64, @floatFromInt(exec_time)) / 1000.0, exec_time });
    std.debug.print("Result: {d}\n", .{stack[0]});

    try std.testing.expectEqual(@as(u256, 10000), stack[0]);
    std.debug.print("[PASS]\n", .{});
}
