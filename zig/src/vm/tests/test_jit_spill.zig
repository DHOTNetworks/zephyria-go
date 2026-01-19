const std = @import("std");
const testing = std.testing;
const evm_mod = @import("vm");
const BigInt = @import("core").BigInt;

test "JIT Spilling: Heavy Stack Pressure" {
    // This test forces the JIT to spill registers by pushing more items than available banks (5).
    // It pushes 8 constants, then performs operations.
    // Banks: 5. Needed: 8. Spills: 3.

    const allocator = testing.allocator;
    var evm = try evm_mod.EVM.init(allocator);
    defer evm.deinit();

    evm.jit_enabled = true;
    evm.engine_type = .native_vm;

    // Bytecode:
    // PUSH1 0x01 ... PUSH1 0x08 (8 items)
    // ADD (add 0x08 + 0x07) -> 0x0F
    // ...
    // We want to force spills.
    // Simple: PUSH1 1, PUSH1 2, ... PUSH1 8.
    // Then POP 7 times? No, we need them live.
    // ADD top 2.

    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x60, 0x05, // PUSH1 5
        0x60, 0x06, // PUSH1 6
        0x60, 0x07, // PUSH1 7
        0x60, 0x08, // PUSH1 8
        0x01, // ADD (Stack: 1 2 3 4 5 6 15)
        0x01, // ADD (Stack: 1 2 3 4 5 21)
        0x01, // ADD (Stack: 1 2 3 4 26)
        0x01, // ADD (Stack: 1 2 3 30)
        0x01, // ADD (Stack: 1 2 33)
        0x01, // ADD (Stack: 1 35)
        0x01, // ADD (Stack: 36)
    };

    evm.code = &bytecode;
    try evm.execute();

    try testing.expectEqual(word(36), evm.stack.pop().?);
}

test "Memory Leak Check: Account Deinit" {
    // Verification that Account.deinit works (via EVM.deinit)
    // Run with leak check enabled by testing.allocator.
    var allocator = testing.allocator;
    var evm = try evm_mod.EVM.init(allocator);

    const addr = [_]u8{0xAA} ** 20;
    const account = evm_mod.Account{
        .balance = BigInt.zero(),
        .nonce = 0,
        .code = try allocator.dupe(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }),
        .storage = std.AutoHashMap(BigInt, BigInt).init(allocator),
    };
    try evm.accounts.put(addr, account);

    evm.deinit();
    // If we missed deinit, allocator would panic on leak at end of test.
}

fn word(v: u64) BigInt {
    return BigInt.init(v);
}
