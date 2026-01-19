const std = @import("std");
const vm = @import("vm");
const EVM = vm.EVM;
const CallFrame = vm.CallFrame;
const Stack = vm.Stack;
const Memory = vm.Memory;
const BigInt = vm.BigInt;

test "Nested CALL execution" {
    const allocator = std.testing.allocator;
    var evm = try EVM.init(allocator);
    evm.jit_enabled = true;
    evm.engine_type = .native_vm;
    defer evm.deinit();

    // Accounts
    const sender = [_]u8{0x01} ** 20;
    const contract_a = [_]u8{0xAA} ** 20;
    const contract_b = [_]u8{0xBB} ** 20;

    // Contract B: Returns 0x42
    // PUSH1 0x42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const code_b = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20 (32 bytes)
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    // Contract A: Calls B, copies return data
    // PUSH1 0 (retSize), PUSH1 0 (retOffset), PUSH1 0 (argsSize), PUSH1 0 (argsOffset), PUSH1 0 (value), PUSH20 <addrB>, PUSH2 1000 (gas), CALL
    // POP (pop success)
    // RETURNDATASIZE, PUSH1 0, MSTORE (check logic manually or use RETURNDATACOPY logic)
    // Since RETURNDATACOPY opcode isn't fully robust yet maybe?
    // Let's rely on memory write from CALL.
    // CALL with retOffset=0, retSize=32.
    // Memory[0..32] should be 0x42...

    // Opcode Sequence for A:
    // PUSH1 32 (retSize)
    // PUSH1 0 (retOffset)
    // PUSH1 0 (argsSize)
    // PUSH1 0 (argsOffset)
    // PUSH1 0 (value)
    // PUSH20 <contract_b>
    // PUSH2 20000 (gas)
    // CALL
    // POP

    var code_a_list = std.ArrayListUnmanaged(u8){};
    defer code_a_list.deinit(allocator);

    try code_a_list.appendSlice(allocator, &[_]u8{ 0x60, 0x20 }); // PUSH1 32 (retSize)
    try code_a_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00 }); // PUSH1 0 (retOffset)
    try code_a_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00 }); // PUSH1 0 (argsSize)
    try code_a_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00 }); // PUSH1 0 (argsOffset)
    try code_a_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00 }); // PUSH1 0 (value)

    try code_a_list.append(allocator, 0x73); // PUSH20
    try code_a_list.appendSlice(allocator, &contract_b);

    try code_a_list.appendSlice(allocator, &[_]u8{ 0x61, 0x4E, 0x20 }); // PUSH2 20000
    try code_a_list.append(allocator, 0xF1); // CALL
    try code_a_list.append(allocator, 0x50); // POP (success bool)
    try code_a_list.append(allocator, 0x00); // STOP

    const code_a = code_a_list.items;

    // Setup accounts
    try evm.accounts.put(contract_b, .{
        .nonce = 0,
        .balance = BigInt.zero(),
        .code = try allocator.dupe(u8, code_b),
        .storage = std.AutoHashMap(BigInt, BigInt).init(allocator),
    });
    // EVM accounts map takes ownership? No, values are structs.
    // Account struct has slice. Account doesn't have deinit.
    // We must ensure the slice is freed.
    // Hack: keep track of it?
    // Or just leak for now if too complex? User asked to solve leak.
    // We can't easily free it here because it's inside the map.
    // Unless we iterate map at end and free codes?
    defer {
        // Cleanup accounts code
        var it = evm.accounts.valueIterator();
        while (it.next()) |acc| {
            // Only free if it was the one we allocated?
            // contract_b code.
            if (acc.code.len == code_b.len) { // unsafe heuristic?
                allocator.free(acc.code);
            }
        }
    }

    // Run EVM execution on A
    // Manually setup initial frame? Or use enterCall?
    // main.execute expects initial state. We can use EVM.init and set fields.
    evm.code = code_a;
    evm.pc = 0;
    evm.gas = 100000;
    evm.caller_address = sender;
    evm.current_address = contract_a;

    // Execute
    try evm.execute();

    // Verify results
    // Memory at 0 should be 0x42 (padded to 32 bytes)
    // MSTORE 0x42 at 0 -> 00...0042 (32 bytes).
    // So byte 31 is 0x42.
    const val = evm.memory.loadByte(31);
    try std.testing.expectEqual(@as(u8, 0x42), val);

    // Byte 0 should be 0
    try std.testing.expectEqual(@as(u8, 0), evm.memory.loadByte(0));
}

test "CREATE contract" {
    const allocator = std.testing.allocator;
    var evm = try EVM.init(allocator);
    evm.jit_enabled = true;
    evm.engine_type = .native_vm;
    defer evm.deinit();

    const sender = [_]u8{0x01} ** 20;

    // Init Code:
    // PUSH1 0x42, PUSH1 0, MSTORE (store code in mem)
    // PUSH1 32, PUSH1 0, RETURN (return code)
    // Contract Code (returned) will be: 00...42 (32 bytes)
    const init_code = &[_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3 };

    // Main Code: CREATE
    // PUSH1 10 (size), PUSH1 0 (offset), PUSH1 0 (value), CREATE
    // PUSH1 0, MSTORE (store address at 0)

    var code_list = std.ArrayListUnmanaged(u8){};
    defer code_list.deinit(allocator);

    // We need init_code in Memory first.
    // So: MCOPY/MSTORE it.
    // Simplest: PUSH bytes one by one and MSTORE8? Or PUSH data and MSTORE.
    // init_code is short (10 bytes).
    // PUSH10 <init_code>
    // PUSH1 0
    // MSTORE

    try code_list.append(allocator, 0x69); // PUSH10
    try code_list.appendSlice(allocator, init_code);
    try code_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x52 }); // PUSH1 0, MSTORE (at 0, padded)
    // But MSTORE writes 32 bytes. 10 bytes at end.
    // So init_code is at memory[22..32].
    // We want memory[0..10].
    // MSTORE Puts at 0. Bytes are 00..00<init_code>.
    // So we should pass offset 22, size 10 to CREATE.

    try code_list.appendSlice(allocator, &[_]u8{ 0x60, 0x0A }); // PUSH1 10 (size)
    try code_list.appendSlice(allocator, &[_]u8{ 0x60, 22 }); // PUSH1 22 (offset)
    try code_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00 }); // PUSH1 0 (value)
    try code_list.append(allocator, 0xF0); // CREATE

    // Result is Address.
    // Check if non-zero.
    try code_list.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x55 }); // SSTORE at 0
    try code_list.append(allocator, 0x00); // STOP

    evm.code = code_list.items;
    evm.pc = 0;
    evm.gas = 100000;
    evm.caller_address = sender;
    evm.current_address = sender;

    try evm.execute();

    // Verify SSTORE key 0 is non-zero
    const sender_account = evm.accounts.get(sender).?;
    const val = sender_account.storage.get(BigInt.zero()) orelse BigInt.zero();
    try std.testing.expect(!val.isZero());
}
