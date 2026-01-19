const std = @import("std");
const EVM = @import("vm").EVM;
const BigInt = @import("vm").BigInt;
const Opcode = @import("vm").Opcode;

test "Cancun: TLOAD and TSTORE basic functionality" {
    const allocator = std.testing.allocator;
    var evm = try EVM.init(allocator);
    defer evm.deinit();

    // 1. TSTORE(key=1, value=42)
    // 2. TLOAD(key=1) -> 42
    // 3. TLOAD(key=2) -> 0
    const bytecode = &[_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x01, // PUSH1 1
        0x5d, // TSTORE (key=1, val=42)
        0x60, 0x01, // PUSH1 1
        0x5c, // TLOAD (key=1) -> should be 42
        0x60, 0x02, // PUSH1 2
        0x5c, // TLOAD (key=2) -> should be 0
    };

    evm.code = bytecode;
    try evm.execute();

    // Verification
    // Stack top should be 0 (result of last TLOAD)
    const res2 = evm.stack.pop().?;
    try std.testing.expect(res2.isZero());

    // Next item should be 42 (result of first TLOAD)
    const res1 = evm.stack.pop().?;
    try std.testing.expectEqual(@as(u64, 42), res1.data[0]);
}

test "Cancun: MCOPY functionality" {
    const allocator = std.testing.allocator;
    var evm = try EVM.init(allocator);
    defer evm.deinit();

    // Setup memory: [1, 2, 3, 4] at offset 0
    // MCOPY(dest=10, src=0, size=4) -> memory[10..14] = [1, 2, 3, 4]

    // Bytecode:
    // PUSH1 0x01, PUSH1 0x00, MSTORE8 // mem[0] = 1
    // PUSH1 0x02, PUSH1 0x01, MSTORE8 // mem[1] = 2
    // PUSH1 0x03, PUSH1 0x02, MSTORE8 // mem[2] = 3
    // PUSH1 0x04, PUSH1 0x03, MSTORE8 // mem[3] = 4
    // PUSH1 0x04, PUSH1 0x00, PUSH1 0x0A, MCOPY // MCOPY(10, 0, 4)

    // 0x5e = MCOPY
    const bytecode = &[_]u8{ 0x60, 0x01, 0x60, 0x00, 0x53, 0x60, 0x02, 0x60, 0x01, 0x53, 0x60, 0x03, 0x60, 0x02, 0x53, 0x60, 0x04, 0x60, 0x03, 0x53, 0x60, 0x04, 0x60, 0x00, 0x60, 0x0A, 0x5e };
    evm.jit_enabled = false;
    evm.code = bytecode;
    try evm.execute();

    // Verify memory results
    try std.testing.expectEqual(@as(u8, 1), evm.memory.loadByte(10));
    try std.testing.expectEqual(@as(u8, 2), evm.memory.loadByte(11));
    try std.testing.expectEqual(@as(u8, 3), evm.memory.loadByte(12));
    try std.testing.expectEqual(@as(u8, 4), evm.memory.loadByte(13));
}
