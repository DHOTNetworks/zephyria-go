const std = @import("std");
const EVM = @import("vm").EVM;
const BigInt = @import("vm").BigInt;

// Hex string of the compiled Token contract
const BYTECODE_HEX = "6080604052348015600e575f5ffd5b50620f42405f5f3373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020015f2081905550610555806100605f395ff3fe608060405234801561000f575f5ffd5b506004361061003f575f3560e01c806327e235e31461004357806370a0823114610073578063a9059cbb146100a3575b5f5ffd5b61005d6004803603810190610058919061031d565b6100d3565b60405161006a9190610360565b60405180910390f35b61008d6004803603810190610088919061031d565b6100e7565b60405161009a9190610360565b60405180910390f35b6100bd60048036038101906100b891906103a3565b61012c565b6040516100ca91906103fb565b60405180910390f35b5f602052805f5260405f205f915090505481565b5f5f5f8373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020015f20549050919050565b5f815f5f3373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020015f205410156101ac576040517f08c379a00000000000000000000000000000000000000000000000000000000081526004016101a39061046e565b60405180910390fd5b815f5f3373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020015f205f8282546101f791906104b9565b92505081905550815f5f8573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020015f205f82825461024991906104ec565b925050819055508273ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef846040516102ad9190610360565b60405180910390a36001905092915050565b5f5ffd5b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b5f6102ec826102c3565b9050919050565b6102fc816102e2565b8114610306575f5ffd5b50565b5f81359050610317816102f3565b92915050565b5f60208284031215610332576103316102bf565b5b5f61033f84828501610309565b91505092915050565b5f819050919050565b61035a81610348565b82525050565b5f6020820190506103735f830184610351565b92915050565b61038281610348565b811461038c575f5ffd5b50565b5f8135905061039d81610379565b92915050565b5f5f604083850312156103b9576103b86102bf565b5b5f6103c685828601610309565b92505060206103d78582860161038f565b9150509250929050565b5f8115159050919050565b6103f5816103e1565b82525050565b5f60208201905061040e5f8301846103ec565b92915050565b5f82825260208201905092915050565b7f496e737566696369656e742062616c616e63650000000000000000000000005f82015250565b5f610458601483610414565b915061046382610424565b602082019050919050565b5f6020820190508181035f8301526104858161044c565b9050919050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b5f6104c382610348565b91506104ce83610348565b92508282039050818111156104e6576104e561048c565b5b92915050565b5f6104f682610348565b915061050183610348565b92508282019050808211156105195761051861048c565b5b9291505056fea26469706673582212207867bc9b5ecfec29f71806553bf859716ffb10e1413b4d8d9c9082aea3f7e23164736f6c6343000821003300";

fn parseHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    var len: usize = 0;
    for (hex) |c| {
        if (!std.ascii.isWhitespace(c)) len += 1;
    }

    if (len % 2 != 0) return error.InvalidHexLength;

    var result = try allocator.alloc(u8, len / 2);

    var ri: usize = 0;
    var high_nibble: ?u8 = null;

    for (hex) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        const digit = try std.fmt.charToDigit(c, 16);
        if (high_nibble) |h| {
            result[ri] = (h << 4) | digit;
            ri += 1;
            high_nibble = null;
        } else {
            high_nibble = digit;
        }
    }
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Running Token Integration Test ===\n", .{});

    const bytecode = try parseHex(allocator, BYTECODE_HEX);
    defer allocator.free(bytecode);

    std.debug.print("Bytecode length: {d} bytes\n", .{bytecode.len});

    var evm = try EVM.init(allocator);
    defer evm.deinit();

    evm.setGasLimit(10_000_000);
    evm.engine_type = .native_vm;
    evm.code = bytecode;
    try evm.memory.resize(allocator, 1024 * 1024);
    try evm.stack.items.ensureTotalCapacity(allocator, 1024);

    const deployer_addr = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x13, 0x37 };

    // We do NOT set evm.current_caller because we set ctx.caller explicitly.

    std.debug.print("Deploying contract...\n", .{});

    const final_stack_top = try evm.native_compiler.compile_bytecode(bytecode);
    const func: *const fn ([*]u256, *const @import("vm").jit.JitContext) callconv(.c) void = @ptrCast(@alignCast(evm.native_compiler.getFunction()));

    const JitContext = @import("vm").jit.JitContext;

    const Storage = std.AutoHashMap([32]u8, [32]u8);
    var storage = Storage.init(allocator);
    defer storage.deinit();

    const TestCtx = struct {
        storage: *Storage,
    };
    var test_ctx = TestCtx{ .storage = &storage };

    const Callbacks = struct {
        pub fn sload(db_ptr: *anyopaque, key_ptr: *const [32]u8, val_ptr: *[32]u8) callconv(.c) void {
            const self: *TestCtx = @ptrCast(@alignCast(db_ptr));
            const val = self.storage.get(key_ptr.*) orelse [_]u8{0} ** 32;
            val_ptr.* = val;
        }
        pub fn sstore(db_ptr: *anyopaque, key_ptr: *const [32]u8, val_ptr: *const [32]u8) callconv(.c) void {
            std.debug.print("SSTORE called\n", .{});
            const self: *TestCtx = @ptrCast(@alignCast(db_ptr));
            self.storage.put(key_ptr.*, val_ptr.*) catch {};
        }
        pub fn log(db_ptr: *anyopaque, mem_ptr: [*]const u8, offset: usize, size: usize, topics_ptr: [*]const [32]u8, num_topics: usize) callconv(.c) void {
            _ = db_ptr;
            _ = mem_ptr;
            _ = offset;
            _ = size;
            _ = topics_ptr;
            _ = num_topics;
            std.debug.print("LOG emitted (Mock)\n", .{});
        }
        pub fn sha3(mem_ptr: [*]const u8, offset: usize, size: usize, res_ptr: *[32]u8) callconv(.c) void {
            const input = mem_ptr[offset..][0..size];
            std.crypto.hash.sha3.Keccak256.hash(input, res_ptr, .{});
        }
    };

    var ctx = JitContext{
        .stack_base = @ptrCast(@alignCast(evm.stack.items.items.ptr)),
        .memory_ptr = evm.memory.raw_ptr,
        .memory_len = evm.memory.committed_len,
        .calldata_ptr = undefined,
        .calldata_len = 0,
        .returndata_ptr = undefined,
        .returndata_len = 0,
        .address = [_]u8{0} ** 20, // Contract Addr
        ._pad1 = undefined,
        .caller = deployer_addr, // msg.sender
        ._pad2 = undefined,
        .origin = deployer_addr, // tx.origin
        ._pad3 = undefined,
        .call_value = [_]u8{0} ** 32,
        .chain_id = 1,
        .block_number = 1,
        .timestamp = 1000,
        .gas_limit = 10_000_000,
        .gas_price = 10,
        .base_fee = 10,
        .prevrandao = [_]u8{0} ** 32,
        .coinbase = [_]u8{0} ** 20,
        ._pad4 = undefined,
        .gas_remaining = 10_000_000,
        .bytecode_ptr = bytecode.ptr,
        .bytecode_len = bytecode.len,
        .db = @ptrCast(&test_ctx),
        .evm_sload = Callbacks.sload,
        .evm_sstore = Callbacks.sstore,
        .evm_sha3 = Callbacks.sha3,
        .evm_balance = undefined,
        .evm_blockhash = undefined,
        .evm_extcodesize = undefined,
        .evm_extcodehash = undefined,
        .evm_extcodecopy = undefined,
        .evm_log = Callbacks.log,
        .evm_call = undefined,
        .evm_callcode = undefined,
        .evm_delegatecall = undefined,
        .evm_staticcall = undefined,
        .evm_create = undefined,
        .evm_create2 = undefined,
        .is_static = false,
        .is_halt = false,
        .is_revert = false,
    };

    // Execute Deployment
    func(@ptrCast(@alignCast(evm.stack.items.items.ptr)), &ctx);
    std.debug.print("Contract execution finished successfully.\n", .{});
    evm.stack.items.items.len = final_stack_top;

    std.debug.print("Deployment finished. Halt: {any}, Revert: {any}\n", .{ ctx.is_halt, ctx.is_revert });

    if (ctx.is_revert) {
        std.debug.print("DEPLOYMENT REVERTED!\n", .{});
        return error.DeploymentReverted;
    }

    // Verify Initial Balance
    var key_data: [64]u8 = undefined;
    @memset(key_data[0..], 0);
    @memcpy(key_data[12..32], deployer_addr[0..]);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&key_data, &hash, .{});

    const bal_bytes = storage.get(hash);
    if (bal_bytes) |bal| {
        const balance = std.mem.readInt(u128, bal[16..32], .big);
        std.debug.print("Deployer Balance: {d}\n", .{balance});
    } else {
        std.debug.print("Deployer Balance: not found (ERROR)\n", .{});
    }
}
