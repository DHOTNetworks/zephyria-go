pub const JitContext = extern struct {
    stack_base: [*]u256,
    memory_ptr: [*]u8,
    memory_len: usize,
    calldata_ptr: [*]const u8,
    calldata_len: usize,
    address: [20]u8,
    caller: [20]u8,
    origin: [20]u8,
    call_value: [32]u8, // u256 as bytes
};
