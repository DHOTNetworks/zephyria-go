pub const JitContext = extern struct {
    // Stack and memory
    stack_base: [*]u256,
    memory_ptr: [*]u8,
    memory_len: usize,

    // Calldata
    calldata_ptr: [*]const u8,
    calldata_len: usize,

    // Return data
    returndata_ptr: [*]u8,
    returndata_len: usize,

    // Contract context
    address: [20]u8,
    _pad1: [4]u8, // Align to 8 bytes (56+24=80)
    caller: [20]u8,
    _pad2: [4]u8, // Align to 8 bytes (80+24=104)
    origin: [20]u8,
    _pad3: [4]u8, // Align to 8 bytes (104+24=128)
    call_value: [32]u8, // 128+32 = 160 (Aligned)

    // Block context
    chain_id: u64,
    block_number: u64,
    timestamp: u64,
    gas_limit: u64,
    gas_price: u64,
    base_fee: u64,
    prevrandao: [32]u8,
    coinbase: [20]u8,
    _pad4: [4]u8, // Align

    // Gas tracking
    gas_remaining: u64,

    // Bytecode
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,

    // State access
    db: *anyopaque, // Pointer to GlobalState

    // Runtime callbacks
    evm_sload: *const fn (ctx: *anyopaque, key_ptr: *const [32]u8, res_ptr: *[32]u8) callconv(.c) void,
    evm_sstore: *const fn (ctx: *anyopaque, key_ptr: *const [32]u8, val_ptr: *const [32]u8) callconv(.c) void,
    evm_sha3: *const fn (mem_ptr: [*]const u8, offset: usize, size: usize, res_ptr: *[32]u8) callconv(.c) void,
    evm_balance: *const fn (ctx: *anyopaque, addr_ptr: *const [20]u8, res_ptr: *[32]u8) callconv(.c) void,
    evm_blockhash: *const fn (ctx: *anyopaque, block_num: u64, res_ptr: *[32]u8) callconv(.c) void,
    evm_extcodesize: *const fn (ctx: *anyopaque, addr_ptr: *const [20]u8) callconv(.c) usize,
    evm_extcodehash: *const fn (ctx: *anyopaque, addr_ptr: *const [20]u8, res_ptr: *[32]u8) callconv(.c) void,
    evm_extcodecopy: *const fn (ctx: *anyopaque, addr_ptr: *const [20]u8, dest_offset: usize, offset: usize, size: usize) callconv(.c) void,
    evm_log: *const fn (ctx: *anyopaque, mem_ptr: [*]const u8, offset: usize, size: usize, topics_ptr: [*]const [32]u8, num_topics: usize) callconv(.c) void,

    // Call family
    evm_call: *const fn (ctx: *anyopaque, gas: u64, addr: *const [20]u8, val: *const [32]u8, arg_off: usize, arg_len: usize, ret_off: usize, ret_len: usize) callconv(.c) bool,
    evm_callcode: *const fn (ctx: *anyopaque, gas: u64, addr: *const [20]u8, val: *const [32]u8, arg_off: usize, arg_len: usize, ret_off: usize, ret_len: usize) callconv(.c) bool,
    evm_delegatecall: *const fn (ctx: *anyopaque, gas: u64, addr: *const [20]u8, arg_off: usize, arg_len: usize, ret_off: usize, ret_len: usize) callconv(.c) bool,
    evm_staticcall: *const fn (ctx: *anyopaque, gas: u64, addr: *const [20]u8, arg_off: usize, arg_len: usize, ret_off: usize, ret_len: usize) callconv(.c) bool,

    // Create family
    evm_create: *const fn (ctx: *anyopaque, val: *const [32]u8, offset: usize, size: usize, res_ptr: *[32]u8) callconv(.c) void,
    evm_create2: *const fn (ctx: *anyopaque, val: *const [32]u8, offset: usize, size: usize, salt: *const [32]u8, res_ptr: *[32]u8) callconv(.c) void,

    // Execution flags
    is_static: bool,
    is_halt: bool,
    is_revert: bool,
};
