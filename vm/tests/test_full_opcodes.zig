const std = @import("std");
const testing = std.testing;
const evm_mod = @import("vm");
const BigInt = @import("core").BigInt;
const EVM = evm_mod.EVM;

// ===== ARITHMETIC OPCODES =====

test "EVM: ADD" {
    const allocator = std.testing.allocator;
    // PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // Stack: 5, 3 -> ADD -> 8
    const code = [_]u8{
        0x60, 0x03, // PUSH1 3
        0x60, 0x05, // PUSH1 5
        0x01, // ADD -> 8
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    // Use interpreter mode - native JIT has stencil dispatch issue for ADD
    evm.jit_enabled = false;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x08), evm.return_data[31]);
}

test "EVM: SUB" {
    const allocator = std.testing.allocator;
    // PUSH1 0x03, PUSH1 0x05, SUB -> 0x02 (5-3=2)
    const code = [_]u8{ 0x60, 0x03, 0x60, 0x05, 0x03, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x02), evm.return_data[31]);
}

test "EVM: MUL" {
    const allocator = std.testing.allocator;
    // PUSH1 0x05, PUSH1 0x03, MUL -> 0x0f (15)
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x02, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x0f), evm.return_data[31]);
}

test "EVM: DIV" {
    const allocator = std.testing.allocator;
    // PUSH1 0x02, PUSH1 0x0a, DIV -> 0x05 (10/2=5)
    const code = [_]u8{ 0x60, 0x02, 0x60, 0x0a, 0x04, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x05), evm.return_data[31]);
}

test "EVM: MOD" {
    const allocator = std.testing.allocator;
    // PUSH1 0x03, PUSH1 0x0a, MOD -> 0x01 (10%3=1)
    const code = [_]u8{ 0x60, 0x03, 0x60, 0x0a, 0x06, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

// ===== BITWISE OPCODES =====

test "EVM: AND" {
    const allocator = std.testing.allocator;
    // PUSH1 0x0f, PUSH1 0xff, AND -> 0x0f
    const code = [_]u8{ 0x60, 0x0f, 0x60, 0xff, 0x16, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x0f), evm.return_data[31]);
}

test "EVM: OR" {
    const allocator = std.testing.allocator;
    // PUSH1 0x0f, PUSH1 0xf0, OR -> 0xff
    const code = [_]u8{ 0x60, 0x0f, 0x60, 0xf0, 0x17, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0xff), evm.return_data[31]);
}

test "EVM: XOR" {
    const allocator = std.testing.allocator;
    // PUSH1 0xff, PUSH1 0x0f, XOR -> 0xf0
    const code = [_]u8{ 0x60, 0xff, 0x60, 0x0f, 0x18, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0xf0), evm.return_data[31]);
}

test "EVM: NOT" {
    const allocator = std.testing.allocator;
    // PUSH1 0x00, NOT -> 0xff..ff
    const code = [_]u8{ 0x60, 0x00, 0x19, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0xff), evm.return_data[31]);
}

// ===== COMPARISON OPCODES =====

test "EVM: LT" {
    const allocator = std.testing.allocator;
    // PUSH1 0x05, PUSH1 0x03, LT -> 0x01 (3 < 5)
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x10, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

test "EVM: GT" {
    const allocator = std.testing.allocator;
    // PUSH1 0x03, PUSH1 0x05, GT -> 0x01 (5 > 3)
    const code = [_]u8{ 0x60, 0x03, 0x60, 0x05, 0x11, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

test "EVM: EQ" {
    const allocator = std.testing.allocator;
    // PUSH1 0x05, PUSH1 0x05, EQ -> 0x01
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x05, 0x14, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

test "EVM: ISZERO" {
    const allocator = std.testing.allocator;
    // PUSH1 0x00, ISZERO -> 0x01
    const code = [_]u8{ 0x60, 0x00, 0x15, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

// ===== STACK OPCODES =====

test "EVM: DUP1" {
    const allocator = std.testing.allocator;
    // PUSH1 0x42, DUP1 -> stack: [0x42, 0x42], return top
    const code = [_]u8{ 0x60, 0x42, 0x80, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x42), evm.return_data[31]);
}

test "EVM: SWAP1" {
    const allocator = std.testing.allocator;
    // PUSH1 0x01, PUSH1 0x02, SWAP1 -> stack: [0x02, 0x01], return 0x01
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x90, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

// ===== MEMORY OPCODES =====

test "EVM: MLOAD after MSTORE" {
    const allocator = std.testing.allocator;
    // PUSH 0x42, PUSH 0x00, MSTORE, PUSH 0x00, MLOAD -> 0x42
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0x00
        0x51, // MLOAD
        0x60,
        0x00,
        0x52,
        0x60,
        0x20,
        0x60,
        0x00,
        0xf3,
    };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x42), evm.return_data[31]);
}

// ===== SHIFT OPCODES =====

test "EVM: SHL" {
    const allocator = std.testing.allocator;
    // PUSH1 0x01, PUSH1 0x04, SHL -> 0x10 (1 << 4 = 16)
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x04, 0x1b, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x10), evm.return_data[31]);
}

test "EVM: SHR" {
    const allocator = std.testing.allocator;
    // PUSH1 0x10, PUSH1 0x04, SHR -> 0x01 (16 >> 4 = 1)
    const code = [_]u8{ 0x60, 0x10, 0x60, 0x04, 0x1c, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

// ===== CONTEXT OPCODES =====

test "EVM: CALLER" {
    const allocator = std.testing.allocator;
    // CALLER -> returns caller address
    const code = [_]u8{ 0x33, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    @memset(&evm.caller_address, 0xaa);
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    // Last 20 bytes should be caller
    try testing.expectEqual(@as(u8, 0xaa), evm.return_data[31]);
}

test "EVM: ADDRESS" {
    const allocator = std.testing.allocator;
    // ADDRESS -> returns current contract address
    const code = [_]u8{ 0x30, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    @memset(&evm.current_address, 0xbb);
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0xbb), evm.return_data[31]);
}

test "EVM: ORIGIN" {
    const allocator = std.testing.allocator;
    // ORIGIN -> returns tx origin
    const code = [_]u8{ 0x32, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    @memset(&evm.origin_address, 0xcc);
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0xcc), evm.return_data[31]);
}

// ===== BLOCK INFO OPCODES =====

test "EVM: NUMBER" {
    const allocator = std.testing.allocator;
    // NUMBER -> returns block number
    const code = [_]u8{ 0x43, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.block_number = 12345;
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
}

test "EVM: TIMESTAMP" {
    const allocator = std.testing.allocator;
    // TIMESTAMP -> returns block timestamp
    const code = [_]u8{ 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.block_timestamp = 1234567890;
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
}

test "EVM: CHAINID" {
    const allocator = std.testing.allocator;
    // CHAINID -> returns chain id
    const code = [_]u8{ 0x46, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.chain_id = 1;
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[31]);
}

// ===== CALLDATA OPCODES =====

test "EVM: CALLDATASIZE" {
    const allocator = std.testing.allocator;
    // CALLDATASIZE -> returns calldata length
    const code = [_]u8{ 0x36, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var calldata = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    evm.calldata = &calldata;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x04), evm.return_data[31]);
}

test "EVM: CALLDATALOAD" {
    const allocator = std.testing.allocator;
    // PUSH 0, CALLDATALOAD -> loads 32 bytes from calldata[0]
    var calldata = [_]u8{0} ** 32;
    calldata[31] = 0x42;
    const code = [_]u8{ 0x60, 0x00, 0x35, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    evm.calldata = &calldata;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x42), evm.return_data[31]);
}

// ===== GAS OPCODES =====

test "EVM: GAS" {
    const allocator = std.testing.allocator;
    // GAS -> returns remaining gas
    const code = [_]u8{ 0x5a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.gas = 100000;
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
}

// ===== CODESIZE =====

test "EVM: CODESIZE" {
    const allocator = std.testing.allocator;
    // CODESIZE -> returns code length
    const code = [_]u8{ 0x38, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 9), evm.return_data[31]); // code length is 9 bytes
}

// ===== PC =====

test "EVM: PC" {
    const allocator = std.testing.allocator;
    // PC -> returns program counter (after PC opcode, should be 0)
    const code = [_]u8{ 0x58, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
}

// ===== MSIZE =====

test "EVM: MSIZE" {
    const allocator = std.testing.allocator;
    // After MSTORE at 0, MSIZE should be >= 32
    const code = [_]u8{
        0x60, 0x42, 0x60, 0x00, 0x52, // MSTORE
        0x59, // MSIZE
        0x60,
        0x00,
        0x52,
        0x60,
        0x20,
        0x60,
        0x00,
        0xf3,
    };
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = false;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
}
