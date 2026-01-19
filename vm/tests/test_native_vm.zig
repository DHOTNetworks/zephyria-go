// File: src/vm/tests/test_native_vm.zig
const std = @import("std");
const EVM = @import("vm").EVM;
const BigInt = @import("vm").BigInt;

test "Native VM Basic Arithmetic" {
    const allocator = std.testing.allocator;
    var evm = try EVM.init(allocator);
    defer evm.deinit();

    // Set engine to Native VM
    evm.engine_type = .native_vm;

    // Small bytecode: PUSH1 5, PUSH1 10, ADD (5+10=15)
    // Note: Native compiler currently loads dummy 0 for constants in the pilot
    // so we expect 0+0=0 for now until emit_load_constant is fully implemented.
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x0a, 0x01 };
    evm.code = &bytecode;

    try evm.execute();

    // Verify result on stack
    const result = evm.stack.pop() orelse return error.TestFailed;
    // Native VM correctly loads constants and adds them now
    try std.testing.expectEqual(@as(u64, 15), result.to(u64));
}
