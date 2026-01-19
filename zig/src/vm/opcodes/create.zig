// File: src/opcodes/create.zig
// CREATE (0xf0): Create a new contract
// Stack: value, offset, size -> address
// Deploys a new contract using keccak256(rlp([sender, nonce]))

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;
const BigInt = @import("../main.zig").BigInt;
const Account = @import("../main.zig").Account;
const crypto = @import("../crypto.zig");

// Gas costs for CREATE
const CREATE_GAS: u64 = 32000;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.CREATE),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    // Check if in static context (CREATE not allowed)
    if (evm.call_stack.isStatic()) {
        return error.StaticCallViolation;
    }

    // Consume base gas
    try evm.consumeGas(CREATE_GAS);

    // Pop stack arguments
    const value_big = evm.stack.pop() orelse return error.StackUnderflow;
    const offset_big = evm.stack.pop() orelse return error.StackUnderflow;
    const size_big = evm.stack.pop() orelse return error.StackUnderflow;

    // Convert to usize
    if (!offset_big.fitsInU64() or !size_big.fitsInU64()) {
        // Push 0 on failure (address creation failed)
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }
    const offset: usize = @intCast(offset_big.data[0]);
    const size: usize = @intCast(size_big.data[0]);

    // Check call depth
    if (evm.call_stack.depth() >= 1024) {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }

    // Get sender account
    const sender_ptr = evm.accounts.getPtr(evm.current_address);
    if (sender_ptr == null) {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }
    var sender = sender_ptr.?;

    // Check if sender has sufficient balance
    if (sender.balance.lt(value_big)) {
        try evm.stack.push(evm.allocator, BigInt.zero());
        return;
    }

    // Read init_code from memory
    try evm.memory.ensureCapacity(evm.allocator, offset + size);
    var init_code = try evm.allocator.alloc(u8, size);
    defer evm.allocator.free(init_code);
    for (0..size) |i| {
        init_code[i] = evm.memory.loadByte(offset + i);
    }

    // Calculate new contract address: keccak256(rlp([sender, nonce]))[12:]
    const new_address = crypto.createAddress(evm.current_address, sender.nonce);

    // Increment sender's nonce
    sender.nonce += 1;

    // Transfer value from sender to new contract
    sender.balance = sender.balance.sub(value_big);

    // Create new account
    const new_account = Account{
        .balance = value_big,
        .nonce = 0, // Contracts start with nonce 0 (or 1 per EIP-161)
        .code = &[_]u8{}, // Will be set after execution
        .storage = std.AutoHashMap(BigInt, BigInt).init(evm.allocator),
    };
    try evm.accounts.put(new_address, new_account);

    // Execute the init code using enterCall
    try evm.enterCall(.{
        .address = new_address,
        .value = value_big,
        .gas = evm.gas, // Pass all remaining gas? (minus 1/64th rule applies to CREATE?)
        .calldata = &[_]u8{}, // No calldata for CREATE (init code is code)
        .code = init_code, // The init code becomes the executing code
        .caller = evm.current_address,
        .code_address = new_address,
        .is_static = false, // CREATE cannot be static
        .is_delegate = false,
        .is_create = true,
        .return_offset = 0,
        .return_size = 0,
    });

    // Note: enterCall switches context.
    // The success/failure (and address push) will be handled by exitCall when the sub-context returns.
    // We do NOT modify stack here.
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    // CREATE: value, offset, size -> address
    if (stack_top.* < 3) return error.StackUnderflow;

    const val_idx = stack_top.* - 1;
    const off_idx = stack_top.* - 2;
    const size_idx = stack_top.* - 3;

    try jit.materialize_slot(@intCast(val_idx));
    try jit.materialize_slot(@intCast(off_idx));
    try jit.materialize_slot(@intCast(size_idx));

    const val_slot = jit.get_virtual_slot(@intCast(val_idx));
    const off_slot = jit.get_virtual_slot(@intCast(off_idx));
    const size_slot = jit.get_virtual_slot(@intCast(size_idx));

    if (val_slot != .register or off_slot != .register or size_slot != .register) {
        return error.JitRegisterAllocationFailed;
    }

    // Result written to size_idx (deepest slot)
    try jit.emit_native_create(val_slot.register, off_slot.register, size_slot.register, size_slot.register);
    jit.pop_virtual(2);
    stack_top.* -= 2;
}
