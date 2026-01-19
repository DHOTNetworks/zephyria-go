const std = @import("std");
const stencils = @import("stencils");
const posix = std.posix;
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;

// Safe page size alignment for ARM64 macOS
const PAGE_SIZE = 16384;

const JumpRelocation = struct {
    patch_offset: usize,
    target_pc: usize,
    instruction_type: enum { B, CBNZ },
};

// Re-export type from interface
const HoleValue = CompilerInterface.HoleValue;

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

    // EIP-1153 Transient Storage
    evm_tload: *const fn (ctx: *anyopaque, key_ptr: *const [32]u8, res_ptr: *[32]u8) callconv(.c) void,
    evm_tstore: *const fn (ctx: *anyopaque, key_ptr: *const [32]u8, val_ptr: *const [32]u8) callconv(.c) void,

    // EIP-5656 MCOPY
    evm_mcopy: *const fn (ctx: *anyopaque, dst_offset: usize, src_offset: usize, size: usize) callconv(.c) void,

    // Memory Expansion
    evm_extend_memory: *const fn (ctx: *anyopaque, new_size: usize) callconv(.c) void,

    // Execution flags
    is_static: bool,
    is_halt: bool,
    is_revert: bool,
    _pad_flags: [5]u8, // Align to 8 bytes (bools are 1 byte)
    evm_ptr: *anyopaque, // Pointer to EVM instance
    _pad_final: [8]u8, // Ensure total size is 8-byte aligned if needed, or just for safety
};

pub const LuffyVM = struct {
    allocator: std.mem.Allocator,
    code_buffer: []align(PAGE_SIZE) u8,
    data_buffer: []u64, // "GOT" for patchable constants
    current_offset: usize,

    // Backpatching
    bytecode_map: std.AutoHashMapUnmanaged(usize, usize), // Bytecode PC -> JIT Offset
    jump_relocs: std.ArrayListUnmanaged(JumpRelocation),

    // Virtual Stack for Constant Propagation & optimization
    virtual_stack: std.ArrayListUnmanaged(CompilerInterface.VirtualSlot),

    pub const VirtualSlot = CompilerInterface.VirtualSlot;

    pub fn init(allocator: std.mem.Allocator, code_size: usize) !LuffyVM {
        const aligned_size = std.mem.alignForward(usize, code_size, PAGE_SIZE);

        const code_ptr = try posix.mmap(
            null,
            aligned_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        );

        const code_slice: []align(PAGE_SIZE) u8 = @alignCast(code_ptr);
        const data_buffer = try allocator.alloc(u64, 1024);
        @memset(code_slice, 0xD5); // Pre-fill with NOPs for safety
        var i: usize = 0;
        while (i < code_slice.len) : (i += 4) {
            std.mem.writeInt(u32, code_slice[i..][0..4], 0xD503201F, .little);
        }

        return LuffyVM{
            .allocator = allocator,
            .code_buffer = code_slice,
            .data_buffer = data_buffer,
            .current_offset = 0,
            .bytecode_map = .{},
            .jump_relocs = .{},
            .virtual_stack = .{},
        };
    }

    pub fn deinit(self: *LuffyVM) void {
        posix.munmap(self.code_buffer);
        self.allocator.free(self.data_buffer);
        self.bytecode_map.deinit(self.allocator);
        self.jump_relocs.deinit(self.allocator);
        self.virtual_stack.deinit(self.allocator);
    }

    pub fn finalize(self: *LuffyVM) !void {
        try self.resolve_jumps();
        try posix.mprotect(self.code_buffer, posix.PROT.READ | posix.PROT.EXEC);

        if (@import("builtin").os.tag.isDarwin()) {
            const sys_icache_invalidate = @extern(*const fn (start: *anyopaque, len: usize) callconv(.c) void, .{ .name = "sys_icache_invalidate" });
            sys_icache_invalidate(self.code_buffer.ptr, self.code_buffer.len);
        }
    }

    pub fn mark_pc(self: *LuffyVM, pc: usize) !void {
        // std.debug.print("[JIT] Marking PC {d} at offset {d}\n", .{ pc, self.current_offset });
        try self.bytecode_map.put(self.allocator, pc, self.current_offset);
    }

    pub fn compiler(self: *LuffyVM) CompilerInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .get_virtual_slot = get_virtual_slot_wrapper,
                .push_virtual_constant = push_virtual_constant_wrapper,
                .push_virtual_memory = push_virtual_memory_wrapper,
                .push_virtual_register = push_virtual_register_wrapper,
                .emit_native_add = emit_native_add_stub,
                .emit_native_mul = emit_native_mul_stub,
                .emit_native_sub = emit_native_sub_stub,
                .emit_native_div = emit_native_div_stub,
                .emit_native_rem = emit_native_rem_stub,
                .emit_native_and = emit_native_and_stub,
                .emit_native_or = emit_native_or_stub,
                .emit_native_xor = emit_native_xor_stub,
                .emit_native_not = emit_native_not_stub,
                .emit_native_mload = emit_native_mload_stub,
                .emit_native_mstore = emit_native_mstore_stub,
                .emit_native_tload = emit_native_tload_stub,
                .emit_native_tstore = emit_native_tstore_stub,
                .emit_native_mcopy = emit_native_mcopy_stub,
                .emit_native_lt = emit_native_lt_stub,
                .emit_native_gt = emit_native_gt_stub,
                .emit_native_eq = emit_native_eq_stub,
                .emit_native_iszero = emit_native_iszero_stub,
                .emit_native_slt = emit_native_slt_stub,
                .emit_native_sgt = emit_native_sgt_stub,

                .emit_native_shl = emit_native_3reg_stub,
                .emit_native_shr = emit_native_3reg_stub,
                .emit_native_sar = emit_native_3reg_stub,
                .emit_native_byte = emit_native_3reg_stub,
                .emit_native_sdiv = emit_native_3reg_stub,
                .emit_native_smod = emit_native_3reg_stub,
                .emit_native_signextend = emit_native_3reg_stub,
                .emit_native_addmod = emit_native_4reg_stub,
                .emit_native_mulmod = emit_native_4reg_stub,
                .emit_native_exp = emit_native_3reg_stub,
                .emit_native_sload = emit_native_2reg_stub,
                .emit_native_sstore = emit_native_2reg_stub,
                .emit_native_calldataload = emit_native_2reg_stub,
                .emit_native_calldatasize = emit_native_1reg_stub,
                .emit_native_calldatacopy = emit_native_3reg_stub,
                .emit_native_sha3 = emit_native_3reg_stub,
                .emit_native_address = emit_native_1reg_stub,
                .emit_native_caller = emit_native_1reg_stub,
                .emit_native_origin = emit_native_1reg_stub,
                .emit_native_callvalue = emit_native_1reg_stub,
                .emit_native_balance = emit_native_2reg_stub,
                .emit_native_selfbalance = emit_native_1reg_stub,
                .emit_native_blockhash = emit_native_2reg_stub,
                .emit_native_msize = emit_native_1reg_stub,
                .emit_native_mstore8 = emit_native_2reg_stub,
                .emit_native_codecopy = emit_native_3reg_stub,
                .emit_native_extcodesize = emit_native_2reg_stub,
                .emit_native_extcodehash = emit_native_2reg_stub,
                .emit_native_extcodecopy = emit_native_4reg_stub,
                .emit_native_returndatacopy = emit_native_3reg_stub,
                .emit_native_return = emit_native_2reg_stub,
                .emit_native_revert = emit_native_2reg_stub,
                .emit_native_log0 = emit_native_2reg_stub,
                .emit_native_log1 = emit_native_3reg_stub,
                .emit_native_log2 = emit_native_4reg_stub,
                .emit_native_log3 = emit_native_5reg_stub,
                .emit_native_log4 = emit_native_6reg_stub,
                .emit_native_call = emit_native_call_stub,
                .emit_native_callcode = emit_native_call_stub,
                .emit_native_delegatecall = emit_native_delegate_stub,
                .emit_native_staticcall = emit_native_delegate_stub,
                .emit_native_create = emit_native_create_stub,
                .emit_native_create2 = emit_native_create2_stub,

                .compile_push = compile_push_wrapper,
                .compile_jump = compile_jump_wrapper,
                .compile_jumpi = compile_jumpi_wrapper,
                .compile_jumpdest = compile_jumpdest_wrapper,
                .compile_pop = compile_pop_wrapper,
                .compile_swap = compile_swap_wrapper,
                .compile_move = compile_move_wrapper,
                .pop_virtual = pop_virtual_wrapper,
                .materialize_slot = materialize_slot_wrapper,
                .sync_virtual_stack = sync_virtual_stack_wrapper,
                .emit_stencil = emit_stencil_wrapper,
            },
        };
    }

    fn compile_push_wrapper(ctx: *anyopaque, dst_idx: u64, value: u256) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_push(dst_idx, value);
    }
    fn compile_jump_wrapper(ctx: *anyopaque, target_pc: usize) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_jump(target_pc);
    }
    fn compile_jumpi_wrapper(ctx: *anyopaque, target_pc: usize, cond_idx: u64) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_jumpi(target_pc, cond_idx);
    }
    fn compile_jumpdest_wrapper(ctx: *anyopaque) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_jumpdest();
    }
    fn compile_pop_wrapper(ctx: *anyopaque, stack_idx: u64) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_pop(stack_idx);
    }
    fn compile_swap_wrapper(ctx: *anyopaque, idx_a: u64, idx_b: u64) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_swap(idx_a, idx_b);
    }
    fn compile_move_wrapper(ctx: *anyopaque, dst: u64, src: u64) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).compile_move(dst, src);
    }

    fn get_virtual_slot_wrapper(ctx: *anyopaque, stack_idx: usize) CompilerInterface.VirtualSlot {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).get_virtual_slot(stack_idx);
    }
    fn push_virtual_constant_wrapper(ctx: *anyopaque, val: u256) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).push_virtual_constant(val);
    }
    fn materialize_slot_wrapper(ctx: *anyopaque, stack_idx: usize) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).materialize_slot(stack_idx);
    }
    fn sync_virtual_stack_wrapper(ctx: *anyopaque, stack_top: u64) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).sync_virtual_stack(stack_top);
    }
    fn emit_stencil_wrapper(ctx: *anyopaque, stencil_name: []const u8, holes: []const CompilerInterface.HoleValue) !void {
        return @as(*LuffyVM, @ptrCast(@alignCast(ctx))).emit_stencil_by_name(stencil_name, holes);
    }
    fn emit_native_add_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_mul_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_sub_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_div_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_rem_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_and_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_or_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_xor_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_not_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_mload_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_mstore_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_lt_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_gt_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_eq_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_iszero_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_slt_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_sgt_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_tload_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_tstore_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_mcopy_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }

    // Generic Stubs for unsupported native ops
    fn emit_native_1reg_stub(_: *anyopaque, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_2reg_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_3reg_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_4reg_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_5reg_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_6reg_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }

    fn emit_native_call_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_delegate_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_create_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }
    fn emit_native_create2_stub(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByStencil;
    }

    fn emit_stencil_by_name(self: *LuffyVM, stencil_name: []const u8, holes: []const CompilerInterface.HoleValue) !void {
        // Map string names to actual stencil objects
        const st = @import("stencils");
        if (std.mem.eql(u8, stencil_name, "Add")) return self.emit_stencil_generic(st.Add, holes);
        if (std.mem.eql(u8, stencil_name, "Mul")) return self.emit_stencil_generic(st.Mul, holes);
        if (std.mem.eql(u8, stencil_name, "Sub")) return self.emit_stencil_generic(st.Sub, holes);
        if (std.mem.eql(u8, stencil_name, "And")) return self.emit_stencil_generic(st.And, holes);
        if (std.mem.eql(u8, stencil_name, "Or")) return self.emit_stencil_generic(st.Or, holes);
        if (std.mem.eql(u8, stencil_name, "Xor")) return self.emit_stencil_generic(st.Xor, holes);
        if (std.mem.eql(u8, stencil_name, "Not")) return self.emit_stencil_generic(st.Not, holes);
        if (std.mem.eql(u8, stencil_name, "Iszero")) return self.emit_stencil_generic(st.Iszero, holes);
        if (std.mem.eql(u8, stencil_name, "Lt")) return self.emit_stencil_generic(st.Lt, holes);
        if (std.mem.eql(u8, stencil_name, "Gt")) return self.emit_stencil_generic(st.Gt, holes);
        if (std.mem.eql(u8, stencil_name, "Eq")) return self.emit_stencil_generic(st.Eq, holes);
        if (std.mem.eql(u8, stencil_name, "Push")) return self.emit_stencil_generic(st.Push, holes);
        if (std.mem.eql(u8, stencil_name, "Mload")) return self.emit_stencil_generic(st.Mload, holes);
        if (std.mem.eql(u8, stencil_name, "Mstore")) return self.emit_stencil_generic(st.Mstore, holes);
        if (std.mem.eql(u8, stencil_name, "Sload")) return self.emit_stencil_generic(st.Sload, holes);
        if (std.mem.eql(u8, stencil_name, "Sstore")) return self.emit_stencil_generic(st.Sstore, holes);
        if (std.mem.eql(u8, stencil_name, "Tload")) return error.StencilNotFound; // TODO: Implement Stencil
        if (std.mem.eql(u8, stencil_name, "Tstore")) return error.StencilNotFound; // TODO: Implement Stencil
        if (std.mem.eql(u8, stencil_name, "Mcopy")) return error.StencilNotFound; // TODO: Implement Stencil
        if (std.mem.eql(u8, stencil_name, "Jumpdest")) return self.emit_stencil_generic(st.Jumpdest, holes);
        if (std.mem.eql(u8, stencil_name, "Origin")) return self.emit_stencil_generic(st.Origin, holes);
        if (std.mem.eql(u8, stencil_name, "Caller")) return self.emit_stencil_generic(st.Caller, holes);
        if (std.mem.eql(u8, stencil_name, "Callvalue")) return self.emit_stencil_generic(st.Callvalue, holes);
        if (std.mem.eql(u8, stencil_name, "Address")) return self.emit_stencil_generic(st.Address, holes);
        if (std.mem.eql(u8, stencil_name, "Calldatasize")) return self.emit_stencil_generic(st.Calldatasize, holes);
        if (std.mem.eql(u8, stencil_name, "Calldataload")) return self.emit_stencil_generic(st.Calldataload, holes);
        if (std.mem.eql(u8, stencil_name, "Calldatacopy")) return self.emit_stencil_generic(st.Calldatacopy, holes);
        if (std.mem.eql(u8, stencil_name, "Div")) return self.emit_stencil_generic(st.Div, holes);
        if (std.mem.eql(u8, stencil_name, "Sgt")) return self.emit_stencil_generic(st.Sgt, holes);
        if (std.mem.eql(u8, stencil_name, "Slt")) return self.emit_stencil_generic(st.Slt, holes);
        if (std.mem.eql(u8, stencil_name, "Mstore8")) return self.emit_stencil_generic(st.Mstore8, holes);
        return error.StencilNotFound;
    }

    fn emit_stencil_generic(self: *LuffyVM, stencil: anytype, holes: []const CompilerInterface.HoleValue) !void {
        var internal_holes: [16]HoleValue = undefined;
        for (holes, 0..) |h, i| {
            internal_holes[i] = .{ .symbol = h.symbol, .value = h.value };
        }
        return self.emit_stencil(stencil, internal_holes[0..holes.len]);
    }

    // --- Virtual Stack Methods ---

    // Ensure the slot at 'stack_idx' is in memory. If it's a constant, emit PUSH.
    pub fn materialize_slot(self: *LuffyVM, stack_idx: usize) !void {
        if (stack_idx >= self.virtual_stack.items.len) return;

        switch (self.virtual_stack.items[stack_idx]) {
            .constant => |val| {
                try self.compile_push_real(stack_idx, val);
                self.virtual_stack.items[stack_idx] = .memory;
            },
            .memory => {
                // For now, in our stencil-based JIT, "materialized" means it's in the stack array.
                // We don't have a sophisticated register allocator yet that moves
                // stack slots into CPU registers (x0-x31).
                // However, our opcodes expect .register for emit_native_*.
                // To bridge this, we treat stack slots as pseudo-registers if they are in memory.
                self.virtual_stack.items[stack_idx] = .{ .register = @intCast(stack_idx) };
            },
            .register => {},
        }
    }

    // Flush all constants to memory (e.g. before branch or label)
    pub fn flush_virtual_stack(self: *LuffyVM) !void {
        for (self.virtual_stack.items, 0..) |_, i| {
            try self.materialize_slot(i);
        }
    }

    // Push a constant to virtual stack (no code emitted)
    pub fn push_virtual_constant(self: *LuffyVM, val: u256) !void {
        std.debug.print("[JIT] push_virtual_constant val={d} new_len={d}\n", .{ @as(u64, @truncate(val)), self.virtual_stack.items.len + 1 });
        try self.virtual_stack.append(self.allocator, .{ .constant = val });
    }

    // Push explicitly as memory (e.g. result of SLOAD)
    fn push_virtual_memory_wrapper(ctx: *anyopaque) !void {
        const self: *LuffyVM = @ptrCast(@alignCast(ctx));
        std.debug.print("[JIT] push_virtual_memory new_len={d}\n", .{self.virtual_stack.items.len + 1});
        try self.virtual_stack.append(self.allocator, .memory);
    }

    // Push explicitly as a register
    fn push_virtual_register_wrapper(ctx: *anyopaque, reg: CompilerInterface.Register) !void {
        const self: *LuffyVM = @ptrCast(@alignCast(ctx));
        try self.virtual_stack.append(self.allocator, .{ .register = reg });
    }

    // Pop n items from virtual stack
    fn pop_virtual_wrapper(ctx: *anyopaque, n: usize) void {
        const self: *LuffyVM = @ptrCast(@alignCast(ctx));
        const old_len = self.virtual_stack.items.len;
        if (n > old_len) {
            // Underflow handled by verifier usually, but safe clamp:
            self.virtual_stack.items.len = 0;
        } else {
            self.virtual_stack.items.len -= n;
        }
        std.debug.print("[JIT] pop_virtual n={d} old_len={d} new_len={d}\n", .{ n, old_len, self.virtual_stack.items.len });
    }

    // Get virtual slot content
    pub fn get_virtual_slot(self: *LuffyVM, stack_idx: usize) VirtualSlot {
        if (stack_idx >= self.virtual_stack.items.len) return .memory; // Fallback
        return self.virtual_stack.items[stack_idx];
    }

    // Sync virtual stack length with actual stack_top, treating new slots as memory
    pub fn sync_virtual_stack(self: *LuffyVM, stack_top: u64) !void {
        const len = self.virtual_stack.items.len;
        if (stack_top < len) {
            std.debug.print("[JIT] sync_virtual_stack shrinking len={d} to top={d}\n", .{ len, stack_top });
            self.virtual_stack.items.len = @intCast(stack_top);
        } else if (stack_top > len) {
            std.debug.print("[JIT] sync_virtual_stack growing len={d} to top={d}\n", .{ len, stack_top });
            const diff = stack_top - len;
            try self.virtual_stack.ensureUnusedCapacity(self.allocator, @intCast(diff));
            for (0..diff) |_| {
                self.virtual_stack.appendAssumeCapacity(.memory);
            }
        }
    }

    // --- End Virtual Stack Methods ---

    fn patch_instruction(self: *LuffyVM, patch_offset: usize, value: u64) !void {
        const inst = std.mem.readInt(u32, self.code_buffer[patch_offset..][0..4], .little);
        if ((inst & 0x9F000000) == 0x90000000) { // ADRP
            const rd = inst & 0x1F;
            if (value > 65535) return error.ValueTooLargeForPatch;
            const movz: u32 = 0xD2800000 | (@as(u32, @intCast(value)) << 5) | rd;
            std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], movz, .little);
        } else if ((inst & 0xFFC00000) == 0xF9400000) { // LDR -> NOP
            std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], 0xD503201F, .little);
            if (patch_offset + 8 <= self.code_buffer.len) {
                const next_inst = std.mem.readInt(u32, self.code_buffer[patch_offset + 4 ..][0..4], .little);
                if ((next_inst & 0xFFC00000) == 0xF9400000) {
                    const rt = inst & 0x1F;
                    const next_rn = (next_inst >> 5) & 0x1F;
                    if (rt == next_rn) {
                        std.mem.writeInt(u32, self.code_buffer[patch_offset + 4 ..][0..4], 0xD503201F, .little);
                    }
                }
            }
        }
    }

    pub fn emit_stencil(self: *LuffyVM, stencil: anytype, patches: []const HoleValue) !void {
        const stencil_code = stencil.code;
        const relocs = stencil.relocs;
        const code_len = stencil_code.len;
        if (self.current_offset + code_len > self.code_buffer.len) return error.OutOfMemory;
        const code_start = self.current_offset;
        @memcpy(self.code_buffer[code_start .. code_start + code_len], &stencil_code);

        var i: usize = 0;
        while (i < code_len) : (i += 4) {
            const inst = std.mem.readInt(u32, self.code_buffer[code_start + i ..][0..4], .little);
            if (inst == 0xa9bf7bfd or inst == 0x910003fd or inst == 0xa8c17bfd or inst == 0xd65f03c0) {
                std.mem.writeInt(u32, self.code_buffer[code_start + i ..][0..4], 0xD503201F, .little);
            }
        }
        for (relocs) |rel| {
            const patch_offset = code_start + rel.offset;
            for (patches) |patch| {
                if (std.mem.eql(u8, rel.symbol, patch.symbol)) {
                    try self.patch_instruction(patch_offset, patch.value);
                    break;
                }
            }
        }
        self.current_offset += code_len;
    }

    pub fn resolve_jumps(self: *LuffyVM) !void {
        for (self.jump_relocs.items) |rel| {
            const target_jit_offset = self.bytecode_map.get(rel.target_pc) orelse {
                // std.debug.print("[JIT] FAILED to resolve jump to PC {d}\n", .{rel.target_pc});
                return error.JumpTargetInvalid;
            };
            const patch_offset = rel.patch_offset;
            // std.debug.print("[JIT] Resolving jump to PC {d} (jit_offset {d}) at patch_offset {d}\n", .{ rel.target_pc, target_jit_offset, patch_offset });
            const branch_offset_bytes = @as(i64, @intCast(target_jit_offset)) - @as(i64, @intCast(patch_offset));
            const imm = @divExact(branch_offset_bytes, 4);
            const inst_encoded = std.mem.readInt(u32, self.code_buffer[patch_offset..][0..4], .little);
            if (rel.instruction_type == .B) {
                var imm26 = @as(u32, @bitCast(@as(i32, @intCast(imm))));
                imm26 &= 0x03FFFFFF;
                const new_inst = (inst_encoded & 0xFC000000) | imm26;
                std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], new_inst, .little);
            } else if (rel.instruction_type == .CBNZ) {
                var imm19 = @as(u32, @bitCast(@as(i32, @intCast(imm))));
                imm19 &= 0x0007FFFF;
                const new_inst = (inst_encoded & 0xFF00001F) | (imm19 << 5);
                std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], new_inst, .little);
            }
        }
    }

    pub fn compile_prologue(self: *LuffyVM) !void {
        const prologue = [_]u32{ 0xa9bf7bfd, 0x910003fd }; // stp x29, x30, [sp, #-16]!; mov x29, sp
        for (prologue, 0..) |inst, i| {
            std.mem.writeInt(u32, self.code_buffer[self.current_offset + i * 4 ..][0..4], inst, .little);
        }
        self.current_offset += 8;
    }

    pub fn compile_epilogue(self: *LuffyVM) !void {
        const epilogue = [_]u32{ 0xa8c17bfd, 0xd65f03c0 }; // ldp x29, x30, [sp], #16; ret
        for (epilogue, 0..) |inst, i| {
            std.mem.writeInt(u32, self.code_buffer[self.current_offset + i * 4 ..][0..4], inst, .little);
        }
        self.current_offset += 8;
    }

    pub fn compile_bytecode(self: *LuffyVM, bytecode: []const u8) !void {
        // const Verifier = @import("verifier.zig").Verifier;
        // var verifier = try Verifier.init(self.allocator, bytecode, .{});
        // defer verifier.deinit();
        // try verifier.verify();

        const opcodes = @import("../opcodes/index.zig");

        // Build dispatch table at comptime
        const JitFn = *const fn (jit: CompilerInterface, pc: *usize, stack_top: *u64, bytecode: []const u8) anyerror!void;
        const jit_dispatch = comptime blk: {
            var table = [_]?JitFn{null} ** 256;
            for (opcodes.all_opcodes) |op_module| {
                const op_info = op_module.getImpl();
                if (@hasDecl(op_module, "jit_compile")) {
                    table[op_info.code] = struct {
                        fn wrapper(w_jit: CompilerInterface, w_pc: *usize, w_stack_top: *u64, w_bytecode: []const u8) anyerror!void {
                            return op_module.jit_compile(w_jit, w_pc, w_stack_top, w_bytecode);
                        }
                    }.wrapper;
                }
            }
            break :blk table;
        };

        try self.compile_prologue();

        var pc: usize = 0;
        var stack_top: u64 = 0;

        while (pc < bytecode.len) {
            const op = bytecode[pc];
            if (op == 0x5b or self.bytecode_map.contains(pc)) {
                try self.flush_virtual_stack();
            }

            try self.mark_pc(pc);
            std.debug.print("[JIT] PC={d} Op=0x{x:0>2} stack_top={d} vstack_len={d}\n", .{ pc, op, stack_top, self.virtual_stack.items.len });

            const is_push = (op >= 0x60 and op <= 0x7F);
            const is_dup = (op >= 0x80 and op <= 0x8F);
            const is_swap = (op >= 0x90 and op <= 0x9F);
            const is_arithmetic = (op == 0x01 or op == 0x03); // ADD, SUB
            const is_jumpi = (op == 0x57);
            const can_handle_virtual = is_push or is_dup or is_swap or is_arithmetic or is_jumpi;

            if (!can_handle_virtual) {
                try self.flush_virtual_stack();
            }

            if (jit_dispatch[op]) |compile_fn| {
                pc += 1;
                try compile_fn(self.compiler(), &pc, &stack_top, bytecode);
            } else {
                // Fallback or handle special cases like JUMPDEST/PUSH if not moved yet
                pc += 1;
                switch (op) {
                    0x5b => try self.compile_jumpdest(),
                    else => return error.UnsupportedOpcode,
                }
            }

            try self.sync_virtual_stack(stack_top);

            // Post-Op flushing for control flow Ops
            if (op == 0x00 or op == 0x56 or op == 0x57 or op == 0x5B or op == 0xF3 or op == 0xFD) {
                try self.flush_virtual_stack();
            }
        }

        try self.flush_virtual_stack();
        try self.compile_epilogue();
        try self.finalize();
    }

    pub fn compile_move(self: *LuffyVM, dst_idx: u64, src_idx: u64) !void {
        const st = @import("stencils");
        try self.emit_stencil_generic(st.Move, &.{
            .{ .symbol = "_HOLE_DST", .value = dst_idx },
            .{ .symbol = "_HOLE_SRC", .value = src_idx },
        });
    }

    pub fn compile_swap(self: *LuffyVM, idx1: u64, idx2: u64) !void {
        const st = @import("stencils");
        try self.emit_stencil_generic(st.Swap, &.{
            .{ .symbol = "_HOLE_DST", .value = idx1 },
            .{ .symbol = "_HOLE_SRC", .value = idx2 },
        });

        const s1 = @as(usize, @intCast(idx1));
        const s2 = @as(usize, @intCast(idx2));
        if (s1 < self.virtual_stack.items.len and s2 < self.virtual_stack.items.len) {
            std.mem.swap(VirtualSlot, &self.virtual_stack.items[s1], &self.virtual_stack.items[s2]);
        }
    }

    pub fn compile_pop(self: *LuffyVM, stack_idx: u64) !void {
        _ = self;
        _ = stack_idx;
        // No-op for now as POP is handled by virtual stack in register JIT
    }

    pub fn addressToU256(_: *LuffyVM, addr: [20]u8) u256 {
        var res: u256 = 0;
        for (addr, 0..) |byte, i| {
            res |= @as(u256, byte) << @intCast(i * 8);
        }
        return res;
    }

    // Original compile_push renamed to internal use mainly
    pub fn compile_push_real(self: *LuffyVM, dst_idx: u64, value: u256) !void {
        const stencil = stencils.Push;
        const code_len = stencil.code.len;
        const jump_inst_offset = self.current_offset + code_len;
        const data_start_offset = std.mem.alignForward(usize, jump_inst_offset + 4, 16);
        const total_len = data_start_offset + 32;

        if (total_len > self.code_buffer.len) return error.OutOfMemory;
        const code_start = self.current_offset;
        @memcpy(self.code_buffer[code_start .. code_start + code_len], &stencil.code);

        var j: usize = 0;
        while (j < code_len) : (j += 4) {
            const inst = std.mem.readInt(u32, self.code_buffer[code_start + j ..][0..4], .little);
            if (inst == 0xa9bf7bfd or inst == 0x910003fd or inst == 0xa8c17bfd or inst == 0xd65f03c0) {
                std.mem.writeInt(u32, self.code_buffer[code_start + j ..][0..4], 0xD503201F, .little);
            }
        }

        const imm = @divExact(@as(i64, @intCast(total_len)) - @as(i64, @intCast(jump_inst_offset)), 4);
        std.mem.writeInt(u32, self.code_buffer[jump_inst_offset..][0..4], 0x14000000 | (@as(u32, @bitCast(@as(i32, @intCast(imm)))) & 0x03FFFFFF), .little);
        std.mem.writeInt(u256, self.code_buffer[data_start_offset..][0..32], value, .little);

        for (stencil.relocs) |rel| {
            const patch_offset = code_start + rel.offset;
            if (std.mem.eql(u8, rel.symbol, "_HOLE_DST")) {
                try self.patch_instruction(patch_offset, dst_idx);
            } else if (std.mem.eql(u8, rel.symbol, "_HOLE_VAL")) {
                const inst = std.mem.readInt(u32, self.code_buffer[patch_offset..][0..4], .little);
                if ((inst & 0x9F000000) == 0x90000000) {
                    const pc_page = patch_offset & ~@as(usize, 0xFFF);
                    const target_page = data_start_offset & ~@as(usize, 0xFFF);
                    const imm_p = @divExact(@as(i64, @intCast(target_page)) - @as(i64, @intCast(pc_page)), 4096);
                    const imm_u = @as(u21, @bitCast(@as(i21, @intCast(imm_p))));
                    std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], (inst & 0x9000001F) | (@as(u32, imm_u & 3) << 29) | (@as(u32, imm_u >> 2) << 5), .little);
                } else if ((inst & 0xFFC00000) == 0xF9400000) {
                    const imm12 = @as(u32, @intCast(data_start_offset & 0xFFF));
                    std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], 0x91000000 | (imm12 << 10) | (((inst >> 5) & 0x1F) << 5) | (inst & 0x1F), .little);
                }
            }
        }
        self.current_offset = total_len;
    }

    // Legacy support for opcodes not yet updated
    pub fn compile_push(self: *LuffyVM, dst_idx: u64, value: u256) !void {
        try self.compile_push_real(dst_idx, value);
    }

    pub fn compile_jump(self: *LuffyVM, target_pc: usize) !void {
        const stencil = stencils.Jump;
        const code_start = self.current_offset;
        @memcpy(self.code_buffer[code_start .. code_start + stencil.code.len], &stencil.code);

        var j: usize = 0;
        while (j < stencil.code.len) : (j += 4) {
            const inst = std.mem.readInt(u32, self.code_buffer[code_start + j ..][0..4], .little);
            if (inst == 0xa9bf7bfd or inst == 0x910003fd or inst == 0xa8c17bfd or inst == 0xd65f03c0) {
                std.mem.writeInt(u32, self.code_buffer[code_start + j ..][0..4], 0xD503201F, .little);
            }
        }
        for (stencil.relocs) |rel| {
            if (std.mem.eql(u8, rel.symbol, "_HOLE_TARGET")) {
                const patch_offset = code_start + rel.offset;
                const inst = std.mem.readInt(u32, self.code_buffer[patch_offset..][0..4], .little);
                if ((inst & 0xFC000000) == 0x94000000) std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], (inst & 0x03FFFFFF) | 0x14000000, .little);
                try self.jump_relocs.append(self.allocator, .{ .patch_offset = patch_offset, .target_pc = target_pc, .instruction_type = .B });
            }
        }
        self.current_offset += stencil.code.len;
    }

    pub fn compile_jumpi(self: *LuffyVM, cond_idx: u64, target_pc: usize) !void {
        const stencil = stencils.Jumpi;
        const code_start = self.current_offset;
        @memcpy(self.code_buffer[code_start .. code_start + stencil.code.len], &stencil.code);
        var j: usize = 0;
        while (j < stencil.code.len) : (j += 4) {
            const inst = std.mem.readInt(u32, self.code_buffer[code_start + j ..][0..4], .little);
            if (inst == 0xa9bf7bfd or inst == 0x910003fd or inst == 0xa8c17bfd or inst == 0xd65f03c0) {
                std.mem.writeInt(u32, self.code_buffer[code_start + j ..][0..4], 0xD503201F, .little);
            }
        }
        for (stencil.relocs) |rel| {
            const patch_offset = code_start + rel.offset;
            if (std.mem.eql(u8, rel.symbol, "_HOLE_COND")) {
                try self.patch_instruction(patch_offset, cond_idx);
            } else if (std.mem.eql(u8, rel.symbol, "_HOLE_TARGET")) {
                const inst = std.mem.readInt(u32, self.code_buffer[patch_offset..][0..4], .little);
                if ((inst & 0xFC000000) == 0x94000000) std.mem.writeInt(u32, self.code_buffer[patch_offset..][0..4], (inst & 0x03FFFFFF) | 0x14000000, .little);
                try self.jump_relocs.append(self.allocator, .{ .patch_offset = patch_offset, .target_pc = target_pc, .instruction_type = .B });
            }
        }
        self.current_offset += stencil.code.len;
    }

    pub fn compile_jumpdest(self: *LuffyVM) !void {
        const st = @import("stencils");
        try self.emit_stencil_generic(st.Jumpdest, &[_]CompilerInterface.HoleValue{});
    }

    pub fn getFunction(self: *LuffyVM) *const anyopaque {
        return @ptrCast(self.code_buffer.ptr);
    }
};
