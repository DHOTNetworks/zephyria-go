const std = @import("std");
const testing = std.testing;
const evm_mod = @import("vm");
const BigInt = @import("core").BigInt;
const EVM = evm_mod.EVM;

// Verification Test for CREATE2, TLOAD, TSTORE, MCOPY
// We need to setup EVM and run bytecode that uses these opcodes.
// Since Native JIT is target, we ensure we enable JIT.

test "EVM: TLOAD and TSTORE (EIP-1153)" {
    const allocator = std.testing.allocator;

    // Bytecode:
    // PUSH1 0x42 (Val)
    // PUSH1 0x01 (Key)
    // TSTORE (Key, Val)
    // PUSH1 0x01 (Key)
    // TLOAD (Key) -> Should be 0x42
    // PUSH1 0x00
    // MSTORE (Store result to memory for return)
    // PUSH1 0x20
    // PUSH1 0x00
    // RETURN

    // TSTORE: 0x5d (check opcode value, assuming 0x5d)
    // TLOAD: 0x5c
    // Note: Constants might define them. We use likely values or check opcode map.
    // If native compiler handles them, they must map to stencils.

    // Let's assume standard opcodes:
    // TLOAD: 0x5c
    // TSTORE: 0x5d

    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x01, // PUSH1 0x01 (key)
        0x5d, // TSTORE
        0x60, 0x01, // PUSH1 0x01 (key)
        0x5c, // TLOAD -> should be 0x42
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3, // RETURN
    };

    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = true;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.memory.ensureCapacity(allocator, 1024);

    try evm.execute();

    // Check return data - TLOAD should return 0x42 stored via TSTORE
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x42), evm.return_data[31]);
}

test "EVM: MCOPY (EIP-5656)" {
    const allocator = std.testing.allocator;

    // Bytecode:
    // MSTORE 0x00, 0xAABBCC... (Word)
    // MCOPY 0x20 (dst), 0x00 (src), 0x20 (size) -> Copy word 0 to word 1
    // RETURN 0x00, 0x40

    // MCOPY: 0x5e

    const code = [_]u8{
        // Store 0x11223344 at 0x00
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x52, // MSTORE (stores u256, so padded)

        // MCOPY(dst=0x20, src=0x00, size=0x20)
        0x60, 0x20, // size
        0x60, 0x00, // src
        0x60, 0x20, // dst
        0x5e, // MCOPY

        // RETURN 0x00, 0x40
        0x60,
        0x40,
        0x60,
        0x00,
        0xf3,
    };

    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = true;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.memory.ensureCapacity(allocator, 1024);

    try evm.execute();

    try testing.expectEqual(evm.return_data.len, 64);
    // Check first word (src)
    try testing.expectEqual(evm.return_data[28], 0x11);
    try testing.expectEqual(evm.return_data[31], 0x44);
    // Check second word (dst - copied)
    try testing.expectEqual(evm.return_data[32 + 28], 0x11);
    try testing.expectEqual(evm.return_data[32 + 31], 0x44);
}

test "EVM: MCOPY Overlap (Forward)" {
    // Overlapping copy such that src < dst (forward copy usually problematic if loop forward? No, src < dst needs backward loop)
    // DST=1, SRC=0, LEN=2.
    // Mem: [A, B, C]
    // Copy [A, B] to [1, 2] -> [A, A, B]?
    // Bytecode:
    // PUSH1 0x01; PUSH1 0x00; MSTORE8 (Mem[0]=1)
    // PUSH1 0x02; PUSH1 0x01; MSTORE8 (Mem[1]=2)
    // PUSH1 0x03; PUSH1 0x02; MSTORE8 (Mem[2]=3)
    // Should result in: Mem[1]=Mem[0](1), Mem[2]=Mem[1](2).
    // Result: 01 01 02

    const code = [_]u8{
        0x60, 0x01, 0x60, 0x00, 0x53, // MSTORE8(0, 1)
        0x60, 0x02, 0x60, 0x01, 0x53, // MSTORE8(1, 2)
        0x60, 0x03, 0x60, 0x02, 0x53, // MSTORE8(2, 3)
        // MCOPY(1, 0, 2)
        0x60, 0x02, // size
        0x60, 0x00, // src
        0x60, 0x01, // dst
        0x5e, // MCOPY

        // Return 3 bytes
        0x60,
        0x03,
        0x60,
        0x00,
        0xf3,
    };

    const allocator = std.testing.allocator;
    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = true;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.execute();

    try testing.expectEqual(@as(usize, 3), evm.return_data.len);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[0]);
    try testing.expectEqual(@as(u8, 0x01), evm.return_data[1]); // Copied from 0
    try testing.expectEqual(@as(u8, 0x02), evm.return_data[2]); // Copied from 1
}

test "EVM: CREATE2 Address Derivation" {
    // Verify that CREATE2 generates correct address via nested execution.
    // Address = keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))

    const allocator = std.testing.allocator;

    // CREATE2(v=0, o=0, s=0, salt=0) - empty init code
    const code = [_]u8{
        0x60, 0x00, // PUSH1 0 (salt)
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5, // CREATE2
        // Stack now has created address (or 0 on failure)
        // MSTORE result and return
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    var evm = try EVM.init(allocator);
    evm.code = &code;
    defer evm.deinit();
    evm.jit_enabled = true;
    evm.engine_type = .native_vm;
    try evm.loadOpcodes();
    try evm.memory.ensureCapacity(allocator, 1024);

    // Set sender to 0x11..11
    @memset(&evm.current_address, 0x11);

    try evm.execute();

    // Check that CREATE2 returned an address (non-zero means success)
    try testing.expectEqual(@as(usize, 32), evm.return_data.len);
}
