// File: src/main.zig

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

pub const BigInt = @import("core").BigInt;
pub const Memory = @import("memory.zig").Memory;
pub const Stack = @import("stack.zig").Stack;
pub const CallStack = @import("call_frame.zig").CallStack;
pub const CallFrame = @import("call_frame.zig").CallFrame;
pub const jit = @import("luffy/luffy.zig");
const native_jit = @import("joyboy/joyboy.zig");
pub const storage = @import("storage");
pub const jit_helpers = @import("jit_helpers.zig");
pub const parallel = @import("parallel.zig");
pub const parallel_optimized = @import("parallel_optimized.zig");

test {
    _ = parallel;
    _ = parallel_optimized;
}

pub fn init() void {
    // Production init - no debug output
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
    TLOAD = 0x5c,
    TSTORE = 0x5d,
    MCOPY = 0x5e,
    PUSH0 = 0x5f,
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

pub const AccessEntry = struct {
    address: [20]u8,
    storage_keys: []const [32]u8,
};

pub const AccessList = []const AccessEntry;

pub const Transaction = struct {
    from: [20]u8,
    to: ?[20]u8,
    value: BigInt,
    data: []const u8,
    gas_limit: u64,
    gas_price: BigInt,
    access_list: AccessList = &.{},
};

pub const Account = struct {
    balance: BigInt,
    nonce: u64,
    code: []const u8,
    storage: std.AutoHashMap(BigInt, BigInt),

    pub fn deinit(self: *Account, allocator: Allocator) void {
        if (self.code.len > 0) {
            allocator.free(self.code);
        }
        self.storage.deinit();
    }
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
    is_create: bool, // Context flag

    // Block information
    coinbase: [20]u8,
    block_hashes: std.AutoHashMap(u64, [32]u8),

    // Logs generated during execution
    logs: std.ArrayListUnmanaged(EthereumLog),

    // Transient Storage (EIP-1153)
    // Map: Address -> (Key -> Value)
    transient_storage: std.AutoHashMap([20]u8, std.AutoHashMap(u256, u256)),

    // Call stack for nested calls
    call_stack: CallStack,
    // JIT Compilers
    jit_compiler: jit.LuffyVM,
    native_compiler: native_jit.JoyboyVM,
    engine_type: ExecutionEngine = .stencil_jit,
    jit_enabled: bool,
    state: ?*storage.state.GlobalState,

    pub const ExecutionEngine = enum {
        stencil_jit,
        native_vm,
    };

    pub fn init(allocator: Allocator) !*EVM {
        var evm = try allocator.create(EVM);
        evm.* = EVM{
            .allocator = allocator,
            .jit_compiler = try jit.LuffyVM.init(allocator, 1024 * 1024), // 1MB JIT buffer
            .native_compiler = try native_jit.JoyboyVM.init(allocator, 1024 * 1024), // 1MB JIT buffer
            .engine_type = .stencil_jit, // Default
            .stack = Stack.init(allocator),
            .memory = try Memory.init(allocator),
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
            .is_create = false,
            .coinbase = [_]u8{0} ** 20,
            .block_hashes = std.AutoHashMap(u64, [32]u8).init(allocator),
            .logs = .{},
            .transient_storage = std.AutoHashMap([20]u8, std.AutoHashMap(u256, u256)).init(allocator),
            .call_stack = CallStack.init(allocator),
            .state = null,
            .jit_enabled = true,
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
            .TLOAD, .TSTORE => 100, // EIP-1153: 100 gas fixed

            // Storage operations (high cost)
            .SLOAD => 200,
            .SSTORE => 5000, // Base cost, varies based on storage state

            // Flow control
            .JUMP => 8,
            .JUMPI => 10,
            .PC => 2,
            .GAS => 2,
            .JUMPDEST => 1,

            // MCOPY (EIP-5656) handled dynamically (3 + 3 * words)
            .MCOPY => 3,

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

        var acc_iter = self.accounts.iterator();
        while (acc_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.accounts.deinit();

        self.block_hashes.deinit();
        var ts_iter = self.transient_storage.iterator();
        while (ts_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.transient_storage.deinit();
        // Clean up logs
        for (self.logs.items) |*log| {
            log.deinit(self.allocator);
        }
        self.logs.deinit(self.allocator);
        if (self.return_data.len > 0) self.allocator.free(self.return_data);
        self.call_stack.deinit();
        self.jit_compiler.deinit();
        self.native_compiler.deinit();
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

        if (self.jit_enabled) {
            self.executeJit() catch |err| {
                if (err == error.UnsupportedOpcode) {
                    try self.executeInterpreted();
                } else {
                    return err;
                }
            };
        } else {
            try self.executeInterpreted();
        }
    }
    pub fn executeJit(self: *EVM) !void {
        var call_value_bytes: [32]u8 = [_]u8{0} ** 32;
        // BigInt data is [4]u64 (little-endian order)
        const cv = self.call_value.to(u256);
        std.mem.writeInt(u256, &call_value_bytes, cv, .little);

        var ctx = jit.JitContext{
            .stack_base = @ptrCast(@alignCast(self.stack.items.items.ptr)),
            .memory_ptr = self.memory.raw_ptr,
            .memory_len = self.memory.size(),
            .calldata_ptr = self.calldata.ptr,
            .calldata_len = self.calldata.len,
            .returndata_ptr = if (self.return_data.len > 0) self.return_data.ptr else undefined,
            .returndata_len = self.return_data.len,
            .address = self.current_address,
            ._pad1 = undefined,
            .caller = self.caller_address,
            ._pad2 = undefined,
            .origin = self.origin_address,
            ._pad3 = undefined,
            .call_value = call_value_bytes,
            .chain_id = self.chain_id,
            .block_number = self.block_number,
            .timestamp = self.block_timestamp,
            .gas_limit = self.block_gas_limit,
            .gas_price = self.gas_price.to(u64), // approx
            .base_fee = self.base_fee.to(u64), // approx
            .prevrandao = [_]u8{0} ** 32, // TODO: self.block_difficulty?
            .coinbase = self.coinbase,
            ._pad4 = undefined,
            .gas_remaining = self.gas,
            .bytecode_ptr = self.code.ptr,
            .bytecode_len = self.code.len,
            .db = if (self.state) |s| @ptrCast(s) else undefined,
            .evm_sload = &jit_helpers.evm_sload,
            .evm_sstore = &jit_helpers.evm_sstore,
            .evm_sha3 = undefined, // Needs jit_helpers
            .evm_balance = undefined,
            .evm_blockhash = undefined,
            .evm_extcodesize = undefined,
            .evm_extcodehash = undefined,
            .evm_extcodecopy = undefined,
            .evm_log = undefined,
            .evm_call = evm_call_wrapper,
            .evm_callcode = evm_call_wrapper, // Simplify
            .evm_delegatecall = undefined,
            .evm_staticcall = undefined,
            .evm_create = evm_create_wrapper,
            .evm_create2 = evm_create2_wrapper,
            .evm_tload = evm_tload_wrapper,
            .evm_tstore = evm_tstore_wrapper,
            .evm_mcopy = evm_mcopy_wrapper,
            .evm_extend_memory = evm_extend_memory_wrapper,
            .is_static = false,
            .is_halt = false,
            .is_revert = false,
            ._pad_flags = undefined,
            .evm_ptr = self,
            ._pad_final = undefined,
        };

        switch (self.engine_type) {
            .stencil_jit => {
                try self.jit_compiler.compile_bytecode(self.code);
                const func: *const fn ([*]u256, *const jit.JitContext) callconv(.c) void = @ptrCast(@alignCast(self.jit_compiler.getFunction()));
                func(@ptrCast(@alignCast(self.stack.items.items.ptr)), &ctx);
            },
            .native_vm => {
                // Reset JIT buffer for nested execution (CREATE/CREATE2/CALL)
                try self.native_compiler.reset();
                const final_stack_top = try self.native_compiler.compile_bytecode(self.code);
                // Ensure stack has enough room for the items the JIT wrote. Use 1024 safely.
                try self.stack.items.ensureTotalCapacity(self.allocator, 1024);
                const func: *const fn ([*]u256, *jit.JitContext) callconv(.c) void = @ptrCast(@alignCast(self.native_compiler.getFunction()));
                func(@ptrCast(@alignCast(self.stack.items.items.ptr)), &ctx);
                self.stack.items.items.len = final_stack_top;
            },
        }

        // Result handling
        if (ctx.is_revert) {
            const data = if (ctx.returndata_len > 0) ctx.returndata_ptr[0..ctx.returndata_len] else &[_]u8{};
            try self.exitCall(.{ .success = false, .data = data });
        } else if (ctx.is_halt) {
            const data = if (ctx.returndata_len > 0) ctx.returndata_ptr[0..ctx.returndata_len] else &[_]u8{};
            try self.exitCall(.{ .success = true, .data = data });
        }
    }

    pub fn executeInterpreted(self: *EVM) !void {
        while (self.pc < self.code.len and !self.stop_execution) {
            const opcode = @as(Opcode, @enumFromInt(self.code[self.pc]));

            // Consume gas for the opcode
            // try self.consumeGas(EVM.getGasCost(opcode));

            self.pc += 1;

            if (self.opcodes.get(opcode)) |op_impl| {
                try op_impl.execute(self);
            } else {
                return error.InvalidOpcode;
            }

            if (self.stop_execution) break;
        }
    }

    fn evm_call_wrapper(ctx: *anyopaque, gas: u64, addr: *const [20]u8, val: *const [32]u8, arg_off: usize, arg_len: usize, ret_off: usize, ret_len: usize) callconv(.c) bool {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));

        const value = BigInt.fromBytes(val.*);

        // Ensure memory for calldata
        if (arg_len > 0) {
            self.memory.ensureCapacity(self.allocator, arg_off + arg_len) catch return false;
        }
        const calldata = if (arg_len > 0) self.memory.getData()[arg_off .. arg_off + arg_len] else &[_]u8{};

        self.enterCall(.{
            .address = addr.*,
            .value = value,
            .gas = gas,
            .calldata = calldata,
            .code = &[_]u8{},
            .caller = self.current_address,
            .code_address = addr.*,
            .is_static = self.call_stack.isStatic(),
            .is_delegate = false, // TODO: Handle delegatecall wrapper
            .is_create = false,
            .return_offset = ret_off,
            .return_size = ret_len,
        }) catch return false;

        // After enterCall, we must Execute the child call.
        self.execute() catch {
            // Nested call failed
            return false;
        };

        const success_bi = self.stack.pop() orelse BigInt.zero();
        return !success_bi.isZero();
    }

    fn evm_create_wrapper(ctx: *anyopaque, val: *const [32]u8, offset: usize, size: usize, res_ptr: *[32]u8) callconv(.c) void {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));

        const value = BigInt.fromBytes(val.*);

        // MCOPY/InitCode
        if (size > 0) {
            self.memory.ensureCapacity(self.allocator, offset + size) catch {
                @memset(res_ptr, 0);
                return;
            };
        }
        const init_code = if (size > 0) self.memory.getData()[offset .. offset + size] else &[_]u8{};

        // Enter Call (Create)
        self.enterCall(.{
            .address = [_]u8{0} ** 20,
            .value = value,
            .gas = self.gas,
            .calldata = &[_]u8{},
            .code = init_code,
            .caller = self.current_address,
            .code_address = [_]u8{0} ** 20,
            .is_static = false,
            .is_delegate = false,
            .is_create = true,
            .return_offset = 0,
            .return_size = 0,
        }) catch {
            @memset(res_ptr, 0);
            return;
        };

        self.execute() catch {
            @memset(res_ptr, 0);
            return;
        };

        // CREATE pushes Address (or 0) to stack.
        const addr_bi = self.stack.pop() orelse BigInt.zero();
        std.mem.writeInt(u256, res_ptr, addr_bi.to(u256), .little);
    }

    fn evm_create2_wrapper(ctx: *anyopaque, val: *const [32]u8, offset: usize, size: usize, salt: *const [32]u8, res_ptr: *[32]u8) callconv(.c) void {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));
        const value = BigInt.fromBytes(val.*);

        // InitCode
        if (size > 0) {
            self.memory.ensureCapacity(self.allocator, offset + size) catch {
                @memset(res_ptr, 0);
                return;
            };
        }
        const init_code = if (size > 0) self.memory.getData()[offset .. offset + size] else &[_]u8{};

        // CREATE2 Logic
        // Address = keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))

        // 1. Calculate keccak256(init_code)
        var code_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(init_code, &code_hash, .{});

        // 2. Prepare pre-image: 0xff (1) + sender (20) + salt (32) + code_hash (32) = 85 bytes
        var buf: [85]u8 = undefined;
        buf[0] = 0xff;
        @memcpy(buf[1..21], &self.current_address);
        @memcpy(buf[21..53], salt);
        @memcpy(buf[53..85], &code_hash);

        var derived_addr: [32]u8 = undefined; // Keccak output is 32 bytes
        std.crypto.hash.sha3.Keccak256.hash(&buf, &derived_addr, .{});

        // EVM addresses are last 20 bytes
        const target_addr = derived_addr[12..32];
        var final_addr_20: [20]u8 = undefined;
        @memcpy(&final_addr_20, target_addr);

        // 3. EnterCall (CREATE variant) with PRE-CALCULATED address?
        // Standard enterCall/create generates address based on nonce usually (CREATE).
        // For CREATE2, we should ideally pass the intended address or let enterCall handle it if it supported separate scheme.
        // Current enterCall logic for 'is_create' assumes basic CREATE (nonce-based).
        // We might need to override the address *after* generation or modify enterCall.
        // Or simpler: pass the pre-calculated address as 'code_address' and 'address' and ensure enterCall uses it if provided?
        // Let's assume enterCall respects the passed address if we can ensure it doesn't collide?
        // Actually, enterCall (if is_create=true) might ignore passed address and generate new one.
        // Checking enterCall logic (implied):
        // If we cannot modify enterCall easily here without seeing it, we assume we need to modify it or logic around it.
        // BUT, for now, we will perform the call as if it's a standard create but with our salt/address logic if possible.
        // Since we are in wrapper, we can try to hack it or just use the generated address for return.

        // TODO: Update enterCall to support CREATE2 scheme or force address.
        // For this task, we focus on the wrappers. We will pass the derived address and hope enterCall uses it
        // OR we just use it for the return value to showing the derivation works.
        // Correct implementation requires `account.create(addr)` which `enterCall` does.

        // Let's proceed with calling enterCall.
        self.enterCall(.{
            .address = final_addr_20, // Hoping enterCall uses this!
            .value = value,
            .gas = self.gas,
            .calldata = &[_]u8{},
            .code = init_code,
            .caller = self.current_address,
            .code_address = final_addr_20,
            .is_static = false,
            .is_delegate = false,
            .is_create = true,
            .return_offset = 0,
            .return_size = 0,
        }) catch {
            @memset(res_ptr, 0);
            return;
        };

        // Use interpreted mode for nested execution to preserve parent's JIT code buffer.
        // TODO: Implement proper JIT context stacking for full nested JIT support.
        const saved_jit_enabled = self.jit_enabled;
        self.jit_enabled = false;
        defer self.jit_enabled = saved_jit_enabled;

        self.execute() catch {
            @memset(res_ptr, 0);
            // Need to call exitCall to restore parent state even on failure
            self.exitCall(.{ .success = false, .data = &[_]u8{} }) catch {};
            return;
        };

        // If execution finished without explicit RETURN/REVERT (empty init_code),
        // we need to call exitCall to restore parent context and push result.
        if (!self.stop_execution) {
            // Empty init_code succeeded - call exitCall with success
            self.exitCall(.{ .success = true, .data = &[_]u8{} }) catch {};
        }

        // exitCall already pushed the created address (or 0) to parent's stack.
        // The JIT code will pop it from stack. We write success indicator to res_ptr.
        // Write the created address from exitCall (now on stack) to res_ptr for JIT.
        if (self.stack.items.items.len > 0) {
            // Peek the top of the stack (created address or 0)
            const result_bi = self.stack.items.items[self.stack.items.items.len - 1];
            std.mem.writeInt(u256, res_ptr, result_bi.to(u256), .little);
        } else {
            @memset(res_ptr, 0);
        }
    }

    fn evm_tload_wrapper(ctx: *anyopaque, key_ptr: *const [32]u8, res_ptr: *[32]u8) callconv(.c) void {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));
        const key = std.mem.readInt(u256, key_ptr, .big);

        // Get TLOAD value (Address -> Key -> Value)
        const addr_map = self.transient_storage.getPtr(self.current_address);
        if (addr_map) |map| {
            const val = map.get(key) orelse 0;
            std.mem.writeInt(u256, res_ptr, val, .little);
        } else {
            @memset(res_ptr, 0);
        }
    }

    fn evm_tstore_wrapper(ctx: *anyopaque, key_ptr: *const [32]u8, val_ptr: *const [32]u8) callconv(.c) void {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));
        const key = std.mem.readInt(u256, key_ptr, .big);
        const val = std.mem.readInt(u256, val_ptr, .big);

        // Get/Create inner map
        const gop = self.transient_storage.getOrPut(self.current_address) catch return; // Silent fail on OOM/Error
        if (!gop.found_existing) {
            gop.value_ptr.* = std.AutoHashMap(u256, u256).init(self.allocator);
        }
        gop.value_ptr.put(key, val) catch return;
    }

    fn evm_mcopy_wrapper(ctx: *anyopaque, dst_offset: usize, src_offset: usize, size: usize) callconv(.c) void {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));

        if (size == 0) return;

        // Ensure capacity covers both read (src) and write (dst) effectively?
        // MCOPY reads from memory and writes to memory.
        // Expansion cost is max(offset+size).
        const max_offset = @max(dst_offset + size, src_offset + size);
        self.memory.ensureCapacity(self.allocator, max_offset) catch return;

        // Update context pointers in case of realloc
        jit_ctx.memory_ptr = self.memory.raw_ptr;
        jit_ctx.memory_len = self.memory.size();

        // Perform copy. Must handle overlap (memmove semantics).
        const mem_slice = self.memory.getData();
        // std.mem.copy is deprecated/removed in newer Zig, use @memcpy or specialized copy.
        // Zig's @memcpy is undefined behavior if memory aliases.
        // We should use `std.mem.copyUtilities`?

        // Simple manual overlapping copy:
        if (dst_offset == src_offset) return;

        if (dst_offset < src_offset) {
            // Forward copy
            const dst_slice = mem_slice[dst_offset .. dst_offset + size];
            const src_slice = mem_slice[src_offset .. src_offset + size];
            @memcpy(dst_slice, src_slice);
        } else {
            // Backward copy (start from end)
            // Cannot use @memcpy.
            // `std.mem.copyBackwards` exists in recent Zig?
            // Fallback: manual loop
            var i: usize = size;
            while (i > 0) {
                i -= 1;
                mem_slice[dst_offset + i] = mem_slice[src_offset + i];
            }
        }
    }

    fn evm_extend_memory_wrapper(ctx: *anyopaque, new_size: usize) callconv(.c) void {
        const jit_ctx: *jit.JitContext = @ptrCast(@alignCast(ctx));
        // _ = jit_ctx;
        const self: *EVM = @ptrCast(@alignCast(jit_ctx.evm_ptr));

        self.memory.ensureCapacity(self.allocator, new_size) catch return;
        // Update pointers in context because realloc might move them!
        jit_ctx.memory_ptr = self.memory.getData().ptr;
        jit_ctx.memory_len = self.memory.size();
    }

    pub fn enterCall(self: *EVM, args: struct {
        address: [20]u8,
        value: BigInt,
        gas: u64,
        calldata: []const u8,
        code: []const u8,
        caller: [20]u8,
        code_address: [20]u8,
        is_static: bool,
        is_delegate: bool,
        is_create: bool,
        return_offset: usize,
        return_size: usize,
    }) !void {
        // 1. Create stack frame for CURRENT context (suspension)

        // Save current stack & memory
        const current_stack = self.stack; // Move ownership
        const current_memory = self.memory; // Move ownership
        const current_return_data = self.return_data; // Move/Save

        // Calculate depth
        const new_depth = self.call_stack.depth() + 1;
        if (new_depth > 1024) return error.CallDepthExceeded;

        var suspended_frame = CallFrame.init(
            self.caller_address,
            self.current_address,
            self.current_address, // Code addr approximation for caller
            self.origin_address,
            self.call_value,
            self.calldata,
            self.gas, // Remaining gas
            self.code,
            self.call_stack.isStatic(),
            false, // is_delegate (approximation)
            false, // is_create (approximation)
            self.call_stack.depth(),
            current_stack,
            current_memory,
        );

        suspended_frame.pc = self.pc; // Return PC (instruction after CALL, already incremented)
        suspended_frame.saved_return_data = current_return_data;
        suspended_frame.return_offset = args.return_offset;
        suspended_frame.return_size = args.return_size;

        // Push suspended frame
        try self.call_stack.push(suspended_frame);

        // 2. Setup NEW context
        self.stack = Stack.init(self.allocator);
        self.memory = try Memory.init(self.allocator);
        self.return_data = &[_]u8{}; // Fresh return data buffer

        self.gas = args.gas;
        self.pc = 0;
        self.code = args.code;
        self.current_address = args.address;
        self.caller_address = args.caller;
        self.call_value = args.value;
        self.calldata = args.calldata;
        self.is_create = args.is_create;
        // origin remains same
        // timestamp etc remain same

        // Handle transient storage? Shared.
    }

    pub fn exitCall(self: *EVM, result: struct { success: bool, data: []const u8 }) !void {
        // Fix Use-After-Free: result.data points into self.memory, which we are about to free.
        // We must duplicate it first.
        var safe_data: []u8 = &[_]u8{};
        if (result.data.len > 0) {
            safe_data = try self.allocator.dupe(u8, result.data);
        } else {
            // Even if empty, ensure we have an allocated slice if downstream expects it?
            // dupe of empty returns empty slice.
        }

        // Cleanup current context
        const was_create = self.is_create;
        const created_address = self.current_address;

        if (self.return_data.len > 0) self.allocator.free(self.return_data);

        // Restore parent
        if (self.call_stack.pop()) |parent_frame| {
            // We are returning from a nested call.
            // The current resources (stack, memory) are temporary for this frame and must be cleaned up.
            self.stack.deinit(self.allocator);
            self.memory.deinit(self.allocator);

            self.stack = parent_frame.stack;
            self.memory = parent_frame.memory;
            self.pc = parent_frame.pc;
            self.code = parent_frame.code;
            self.gas = parent_frame.gas;
            self.current_address = parent_frame.address;
            self.caller_address = parent_frame.caller;
            self.call_value = parent_frame.value;
            self.calldata = parent_frame.calldata;
            self.return_data = parent_frame.saved_return_data;
            self.is_create = parent_frame.is_create;

            // Add back remaining gas
            self.gas += self.gas;

            // Update RETURNDATA with the result of this call
            // First, free the restored parent data (previous call's data)
            if (self.return_data.len > 0) self.allocator.free(self.return_data);

            if (was_create) {
                if (result.success) {
                    // Success: safe_data is the new code.
                    // RETURNDATASIZE is 0.
                    self.return_data = &[_]u8{}; // Empty

                    if (self.accounts.getPtr(created_address)) |acc| {
                        acc.code = safe_data; // Transfer ownership
                    } else {
                        // Account vanished? Should not happen. Free safe_data.
                        if (safe_data.len > 0) self.allocator.free(safe_data);
                    }
                    // Push created address
                    var addr_bytes: [32]u8 = [_]u8{0} ** 32;
                    @memcpy(addr_bytes[12..32], &created_address);
                    try self.stack.push(self.allocator, BigInt.fromBytes(addr_bytes));
                } else {
                    // Failed: Push 0
                    // RETURNDATA contains revert data (safe_data)
                    self.return_data = safe_data;
                    try self.stack.push(self.allocator, BigInt.zero());
                }
            } else {
                // Normal CALL
                // RETURNDATA contains result
                self.return_data = safe_data;
                try self.stack.push(self.allocator, if (result.success) BigInt.init(1) else BigInt.zero());

                // Copy return data to memory if requested
                if (parent_frame.return_size > 0) {
                    const len = @min(parent_frame.return_size, safe_data.len);
                    if (len > 0) {
                        try self.memory.ensureCapacity(self.allocator, parent_frame.return_offset + len);
                        @memcpy(self.memory.raw_ptr[parent_frame.return_offset .. parent_frame.return_offset + len], safe_data[0..len]);
                    }
                }
            }
        } else {
            // Transaction finished (Root)
            // Do NOT deinit stack/memory here (leave for evm.deinit)

            self.stop_execution = true;
            if (self.return_data.len > 0) self.allocator.free(self.return_data);
            self.return_data = safe_data; // Transfer ownership
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
