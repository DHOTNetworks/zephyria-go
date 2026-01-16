// File: src/main.zig

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

pub const BigInt = @import("core").BigInt;
pub const Memory = @import("memory.zig").Memory;
pub const Stack = @import("stack.zig").Stack;
pub const CallStack = @import("call_frame.zig").CallStack;
pub const CallFrame = @import("call_frame.zig").CallFrame;
pub const jit = @import("jit_compiler.zig");

pub fn init() void {
    std.debug.print("VM module initialized\n", .{});
}

pub const Opcode = enum(u8) {
    STOP = 0x00,
    ADD = 0x01,
    MUL = 0x02,
    SUB = 0x03,
    DIV = 0x04,
    SDIV = 0x05,
    MOD = 0x06,
    SMOD = 0x07,
    ADDMOD = 0x08,
    MULMOD = 0x09,
    EXP = 0x0a,
    SIGNEXTEND = 0x0b,
    LT = 0x10,
    GT = 0x11,
    SLT = 0x12,
    SGT = 0x13,
    EQ = 0x14,
    ISZERO = 0x15,
    AND = 0x16,
    OR = 0x17,
    XOR = 0x18,
    NOT = 0x19,
    BYTE = 0x1a,
    SHL = 0x1b,
    SHR = 0x1c,
    SAR = 0x1d,
    SHA3 = 0x20,
    ADDRESS = 0x30,
    BALANCE = 0x31,
    ORIGIN = 0x32,
    CALLER = 0x33,
    CALLVALUE = 0x34,
    CALLDATALOAD = 0x35,
    CALLDATASIZE = 0x36,
    CALLDATACOPY = 0x37,
    CODESIZE = 0x38,
    CODECOPY = 0x39,
    GASPRICE = 0x3a,
    EXTCODESIZE = 0x3b,
    EXTCODECOPY = 0x3c,
    RETURNDATASIZE = 0x3d,
    RETURNDATACOPY = 0x3e,
    EXTCODEHASH = 0x3f,
    BLOCKHASH = 0x40,
    COINBASE = 0x41,
    TIMESTAMP = 0x42,
    NUMBER = 0x43,
    DIFFICULTY = 0x44,
    GASLIMIT = 0x45,
    CHAINID = 0x46,
    SELFBALANCE = 0x47,
    BASEFEE = 0x48,
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    MSTORE8 = 0x53,
    SLOAD = 0x54,
    SSTORE = 0x55,
    JUMP = 0x56,
    JUMPI = 0x57,
    PC = 0x58,
    MSIZE = 0x59,
    GAS = 0x5a,
    JUMPDEST = 0x5b,
    PUSH1 = 0x60,
    PUSH2 = 0x61,
    PUSH3 = 0x62,
    PUSH4 = 0x63,
    PUSH5 = 0x64,
    PUSH6 = 0x65,
    PUSH7 = 0x66,
    PUSH8 = 0x67,
    PUSH9 = 0x68,
    PUSH10 = 0x69,
    PUSH11 = 0x6a,
    PUSH12 = 0x6b,
    PUSH13 = 0x6c,
    PUSH14 = 0x6d,
    PUSH15 = 0x6e,
    PUSH16 = 0x6f,
    PUSH17 = 0x70,
    PUSH18 = 0x71,
    PUSH19 = 0x72,
    PUSH20 = 0x73,
    PUSH21 = 0x74,
    PUSH22 = 0x75,
    PUSH23 = 0x76,
    PUSH24 = 0x77,
    PUSH25 = 0x78,
    PUSH26 = 0x79,
    PUSH27 = 0x7a,
    PUSH28 = 0x7b,
    PUSH29 = 0x7c,
    PUSH30 = 0x7d,
    PUSH31 = 0x7e,
    PUSH32 = 0x7f,
    DUP1 = 0x80,
    DUP2 = 0x81,
    DUP3 = 0x82,
    DUP4 = 0x83,
    DUP5 = 0x84,
    DUP6 = 0x85,
    DUP7 = 0x86,
    DUP8 = 0x87,
    DUP9 = 0x88,
    DUP10 = 0x89,
    DUP11 = 0x8a,
    DUP12 = 0x8b,
    DUP13 = 0x8c,
    DUP14 = 0x8d,
    DUP15 = 0x8e,
    DUP16 = 0x8f,
    SWAP1 = 0x90,
    SWAP2 = 0x91,
    SWAP3 = 0x92,
    SWAP4 = 0x93,
    SWAP5 = 0x94,
    SWAP6 = 0x95,
    SWAP7 = 0x96,
    SWAP8 = 0x97,
    SWAP9 = 0x98,
    SWAP10 = 0x99,
    SWAP11 = 0x9a,
    SWAP12 = 0x9b,
    SWAP13 = 0x9c,
    SWAP14 = 0x9d,
    SWAP15 = 0x9e,
    SWAP16 = 0x9f,
    LOG0 = 0xa0,
    LOG1 = 0xa1,
    LOG2 = 0xa2,
    LOG3 = 0xa3,
    LOG4 = 0xa4,
    CREATE = 0xf0,
    CALL = 0xf1,
    CALLCODE = 0xf2,
    RETURN = 0xf3,
    DELEGATECALL = 0xf4,
    CREATE2 = 0xf5,
    STATICCALL = 0xfa,
    REVERT = 0xfd,
    INVALID = 0xfe,
    SELFDESTRUCT = 0xff,
};

pub const OpcodeImpl = struct {
    execute: *const fn (*EVM) anyerror!void,
};

pub const Transaction = struct {
    from: [20]u8,
    to: ?[20]u8,
    value: BigInt,
    data: []const u8,
    gas_limit: u64,
    gas_price: BigInt,
};

pub const Account = struct {
    balance: BigInt,
    nonce: u64,
    code: []const u8,
    storage: std.AutoHashMap(BigInt, BigInt),
};

/// Ethereum log entry
pub const EthereumLog = struct {
    address: [20]u8,
    topics: std.ArrayListUnmanaged([32]u8),
    data: []u8,

    pub fn init(allocator: Allocator, address: [20]u8) EthereumLog {
        _ = allocator;
        return EthereumLog{
            .address = address,
            .topics = .{},
            .data = &[_]u8{},
        };
    }

    pub fn deinit(self: *EthereumLog, allocator: Allocator) void {
        self.topics.deinit(allocator);
        if (self.data.len > 0) {
            allocator.free(self.data);
        }
    }

    pub fn addTopic(self: *EthereumLog, allocator: Allocator, topic: [32]u8) !void {
        try self.topics.append(allocator, topic);
    }

    pub fn setData(self: *EthereumLog, allocator: Allocator, data: []const u8) !void {
        if (self.data.len > 0) {
            allocator.free(self.data);
        }
        self.data = try allocator.dupe(u8, data);
    }
};

pub const EVM = struct {
    allocator: Allocator,
    stack: Stack,
    memory: Memory,
    pc: usize,
    gas: u64,
    gas_limit: u64,
    gas_used: u64,
    code: []const u8,
    opcodes: std.AutoHashMap(Opcode, OpcodeImpl),
    accounts: std.AutoHashMap([20]u8, Account),
    current_transaction: ?Transaction,

    // Environmental information
    current_address: [20]u8,
    caller_address: [20]u8,
    origin_address: [20]u8,
    call_value: BigInt,
    gas_price: BigInt,
    block_timestamp: u64,
    block_number: u64,
    block_difficulty: BigInt,
    block_gas_limit: u64,
    chain_id: u64,
    base_fee: BigInt,

    // Call data (input to the current execution context)
    calldata: []const u8,

    // Return data from the last external call
    return_data: []u8,

    // Execution state flags
    stop_execution: bool,
    execution_reverted: bool,

    // Block information
    coinbase: [20]u8,
    block_hashes: std.AutoHashMap(u64, [32]u8),

    // Logs generated during execution
    logs: std.ArrayListUnmanaged(EthereumLog),

    // Call stack for nested calls
    call_stack: CallStack,
    jit_compiler: jit.JitCompiler,

    pub fn init(allocator: Allocator) !*EVM {
        var evm = try allocator.create(EVM);
        evm.* = EVM{
            .allocator = allocator,
            .jit_compiler = try jit.JitCompiler.init(allocator, 1024 * 1024), // 1MB JIT buffer
            .stack = Stack.init(allocator),
            .memory = Memory.init(allocator),
            .pc = 0,
            .gas = 21000, // Default gas for basic transaction
            .gas_limit = 21000,
            .gas_used = 0,
            .code = &[_]u8{},
            .opcodes = std.AutoHashMap(Opcode, OpcodeImpl).init(allocator),
            .accounts = std.AutoHashMap([20]u8, Account).init(allocator),
            .current_transaction = null,

            // Initialize environmental values with defaults
            .current_address = [_]u8{0} ** 20,
            .caller_address = [_]u8{0} ** 20,
            .origin_address = [_]u8{0} ** 20,
            .call_value = BigInt.init(0),
            .gas_price = BigInt.init(20000000000), // 20 gwei default
            .block_timestamp = 1640995200, // Default timestamp (Jan 1, 2022)
            .block_number = 1,
            .block_difficulty = BigInt.init(1000000),
            .block_gas_limit = 30000000, // 30M gas limit
            .chain_id = 1, // Ethereum mainnet
            .base_fee = BigInt.init(10000000000), // 10 gwei default
            .calldata = &[_]u8{},
            .return_data = &[_]u8{},
            .stop_execution = false,
            .execution_reverted = false,
            .coinbase = [_]u8{0} ** 20,
            .block_hashes = std.AutoHashMap(u64, [32]u8).init(allocator),
            .logs = .{},
            .call_stack = CallStack.init(allocator),
        };
        try evm.loadOpcodes();
        return evm;
    }

    pub fn setGasLimit(self: *EVM, gas_limit: u64) void {
        self.gas_limit = gas_limit;
        self.gas = gas_limit;
        self.gas_used = 0;
    }

    pub fn getGasCost(opcode: Opcode) u64 {
        return switch (opcode) {
            // Base costs
            .STOP => 0,
            .ADD, .SUB, .MUL, .DIV, .SDIV, .MOD, .SMOD, .ADDMOD, .MULMOD => 3,
            .EXP => 10, // Base cost, actual cost depends on exponent
            .SIGNEXTEND => 5,

            // Comparison operations
            .LT, .GT, .SLT, .SGT, .EQ, .ISZERO => 3,

            // Bitwise operations
            .AND, .OR, .XOR, .NOT, .BYTE => 3,
            .SHL, .SHR, .SAR => 3,

            // Hash operations
            .SHA3 => 30, // Base cost, additional cost per word

            // Environmental operations
            .ADDRESS, .ORIGIN, .CALLER, .GASPRICE, .TIMESTAMP, .NUMBER, .DIFFICULTY, .GASLIMIT, .CHAINID, .BASEFEE => 2,
            .BALANCE => 100, // Account access cost
            .SELFBALANCE => 5,

            // Stack operations
            .POP => 2,
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => 3,

            .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => 3,

            .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => 3,

            // Memory operations
            .MLOAD, .MSTORE, .MSTORE8 => 3,
            .MSIZE => 2,

            // Storage operations (high cost)
            .SLOAD => 200,
            .SSTORE => 5000, // Base cost, varies based on storage state

            // Flow control
            .JUMP => 8,
            .JUMPI => 10,
            .PC => 2,
            .GAS => 2,
            .JUMPDEST => 1,

            // Other operations with default costs
            else => 3,
        };
    }

    pub fn consumeGas(self: *EVM, amount: u64) !void {
        if (self.gas < amount) {
            return error.OutOfGas;
        }
        self.gas -= amount;
        self.gas_used += amount;
    }

    pub fn getGasInfo(self: *EVM) struct { used: u64, remaining: u64, limit: u64 } {
        return .{
            .used = self.gas_used,
            .remaining = self.gas,
            .limit = self.gas_limit,
        };
    }

    pub fn deinit(self: *EVM) void {
        self.stack.deinit(self.allocator);
        self.memory.deinit(self.allocator);
        self.opcodes.deinit();
        self.accounts.deinit();
        self.block_hashes.deinit();
        // Clean up logs
        for (self.logs.items) |*log| {
            log.deinit(self.allocator);
        }
        self.logs.deinit(self.allocator);
        self.call_stack.deinit();
        self.allocator.destroy(self);
    }

    pub fn loadOpcodes(self: *EVM) !void {
        const opcodes = @import("opcodes/index.zig");
        inline for (opcodes.all_opcodes) |op_module| {
            const op_info = op_module.getImpl();
            try self.opcodes.put(@enumFromInt(op_info.code), op_info.impl);
        }
    }

    pub fn execute(self: *EVM) !void {
        // Reset execution flags
        self.stop_execution = false;
        self.execution_reverted = false;

        // Try JIT execution first (PoC: only if code len > 0)
        if (self.code.len > 0) {
            self.executeJit() catch |err| {
                std.debug.print("JIT failed, falling back to interpreter: {s}\n", .{@errorName(err)});
                // Reset pc if JIT failed halfway (simplified)
                self.pc = 0;
                try self.executeInterpreted();
            };
        } else {
            try self.executeInterpreted();
        }
    }
    pub fn executeJit(self: *EVM) !void {
        var jit_comp = try jit.JitCompiler.init(self.allocator, 1024 * 64);
        defer jit_comp.deinit();

        var call_value_bytes: [32]u8 = [_]u8{0} ** 32;
        // BigInt data is [4]u64 (little-endian order)
        const cv = self.call_value.to(u256);
        std.mem.writeInt(u256, &call_value_bytes, cv, .little);

        const ctx = jit.JitContext{
            .stack_base = @ptrCast(@alignCast(self.stack.items.items.ptr)),
            .memory_ptr = self.memory.data.items.ptr,
            .memory_len = self.memory.data.items.len,
            .calldata_ptr = self.calldata.ptr,
            .calldata_len = self.calldata.len,
            .address = self.current_address,
            .caller = self.caller_address,
            .origin = self.origin_address,
            .call_value = call_value_bytes,
        };

        try jit_comp.compile_bytecode(self.code);
        const func: *const fn ([*]u256, *const jit.JitContext) callconv(.c) void = @ptrCast(@alignCast(jit_comp.getFunction()));
        func(@ptrCast(@alignCast(self.stack.items.items.ptr)), &ctx);
    }

    pub fn executeInterpreted(self: *EVM) !void {
        while (self.pc < self.code.len and !self.stop_execution) {
            const opcode = @as(Opcode, @enumFromInt(self.code[self.pc]));

            // Consume gas for the opcode
            const gas_cost = EVM.getGasCost(opcode);
            try self.consumeGas(gas_cost);

            self.pc += 1;

            const impl = self.opcodes.get(opcode) orelse return error.UnknownOpcode;
            try impl.execute(self);

            if (opcode == .STOP) break;
        }
    }

    pub fn applyTransaction(self: *EVM, transaction: Transaction) !void {
        var from_account = try self.getOrCreateAccount(transaction.from);
        if (from_account.balance.lt(transaction.value)) {
            return error.InsufficientBalance;
        }

        from_account.balance = from_account.balance.sub(transaction.value);
        from_account.nonce += 1;

        if (transaction.to) |to| {
            var to_account = try self.getOrCreateAccount(to);
            to_account.balance = to_account.balance.add(transaction.value);

            if (to_account.code.len > 0) {
                self.current_transaction = transaction;
                self.code = to_account.code;
                self.pc = 0;
                self.gas = transaction.gas_limit;
                try self.execute();
                self.current_transaction = null;
            }
        } else {
            // Contract creation
            const new_account = Account{
                .balance = transaction.value,
                .nonce = 0,
                .code = try self.allocator.dupe(u8, transaction.data),
                .storage = std.AutoHashMap(BigInt, BigInt).init(self.allocator),
            };
            // Generate new address (simplified for this example)
            var new_address: [20]u8 = undefined;
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&transaction.from, &hash, .{});
            for (0..20) |i| {
                new_address[i] = hash[i];
            }
            try self.accounts.put(new_address, new_account);
        }
    }

    fn getOrCreateAccount(self: *EVM, address: [20]u8) !*Account {
        if (self.accounts.getPtr(address)) |account| {
            return account;
        } else {
            const new_account = Account{
                .balance = BigInt.init(0),
                .nonce = 0,
                .code = &[_]u8{},
                .storage = std.AutoHashMap(BigInt, BigInt).init(self.allocator),
            };
            try self.accounts.put(address, new_account);
            return self.accounts.getPtr(address).?;
        }
    }
};

// When used as an executable, we provide a main function
// When used as a library, this function won't be called
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var evm = try EVM.init(allocator);
    defer evm.deinit();

    // Directly test our opcodes
    const bytecode = &[_]u8{ 0x60, 0x03, 0x60, 0x04, 0x01, 0x60, 0x02, 0x02, 0x00 }; // PUSH1 3, PUSH1 4, ADD, PUSH1 2, MUL, STOP
    evm.code = bytecode;
    evm.pc = 0;

    try evm.execute();

    std.debug.print("Execution completed successfully\n", .{});

    // Print the result of our computation
    if (evm.stack.pop()) |result| {
        std.debug.print("Result: {d}\n", .{result.data[0]});
    } else {
        std.debug.print("Stack is empty\n", .{});
    }
}
