// File: src/vm/compiler_interface.zig
const std = @import("std");

/// The CompilerInterface defines the contract that any EVM compilation engine
/// (Stencil JIT or Native Register VM) must satisfy.
/// This allows opcodes to be written once and targeted to multiple backends.
pub const CompilerInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // --- Virtual Stack & Registry ---
        get_virtual_slot: *const fn (ctx: *anyopaque, stack_idx: usize) VirtualSlot,
        push_virtual_constant: *const fn (ctx: *anyopaque, val: u256) anyerror!void,
        push_virtual_memory: *const fn (ctx: *anyopaque) anyerror!void,
        push_virtual_register: *const fn (ctx: *anyopaque, reg: Register) anyerror!void,
        pop_virtual: *const fn (ctx: *anyopaque, n: usize) void,
        materialize_slot: *const fn (ctx: *anyopaque, stack_idx: usize) anyerror!void,
        sync_virtual_stack: *const fn (ctx: *anyopaque, stack_top: u64) anyerror!void,

        // --- Emission ---
        emit_stencil: *const fn (ctx: *anyopaque, stencil_name: []const u8, holes: []const HoleValue) anyerror!void,

        // Native Emission (for Register VM)
        emit_native_add: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_mul: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_sub: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_div: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_rem: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_and: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_or: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_xor: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_not: *const fn (ctx: *anyopaque, dst: Register, src1: Register) anyerror!void,
        emit_native_mload: *const fn (ctx: *anyopaque, dst: Register, offset: Register) anyerror!void,
        emit_native_mstore: *const fn (ctx: *anyopaque, offset: Register, val: Register) anyerror!void,
        // Comparisons
        emit_native_lt: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_gt: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_eq: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_iszero: *const fn (ctx: *anyopaque, dst: Register, src1: Register) anyerror!void,
        emit_native_slt: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_sgt: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,

        // Shift Operations
        emit_native_shl: *const fn (ctx: *anyopaque, dst: Register, val: Register, shift: Register) anyerror!void,
        emit_native_shr: *const fn (ctx: *anyopaque, dst: Register, val: Register, shift: Register) anyerror!void,
        emit_native_sar: *const fn (ctx: *anyopaque, dst: Register, val: Register, shift: Register) anyerror!void,
        emit_native_byte: *const fn (ctx: *anyopaque, dst: Register, idx: Register, val: Register) anyerror!void,

        // Signed Arithmetic
        emit_native_sdiv: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_smod: *const fn (ctx: *anyopaque, dst: Register, src1: Register, src2: Register) anyerror!void,
        emit_native_signextend: *const fn (ctx: *anyopaque, dst: Register, b: Register, x: Register) anyerror!void,

        // Modular Arithmetic
        emit_native_addmod: *const fn (ctx: *anyopaque, dst: Register, a: Register, b: Register, n: Register) anyerror!void,
        emit_native_mulmod: *const fn (ctx: *anyopaque, dst: Register, a: Register, b: Register, n: Register) anyerror!void,
        emit_native_exp: *const fn (ctx: *anyopaque, dst: Register, base: Register, exponent: Register) anyerror!void,

        // Storage Operations (with runtime callbacks)
        emit_native_sload: *const fn (ctx: *anyopaque, dst: Register, key: Register) anyerror!void,
        emit_native_sstore: *const fn (ctx: *anyopaque, key: Register, val: Register) anyerror!void,
        emit_native_tload: *const fn (ctx: *anyopaque, dst: Register, key: Register) anyerror!void,
        emit_native_tstore: *const fn (ctx: *anyopaque, key: Register, val: Register) anyerror!void,
        emit_native_mcopy: *const fn (ctx: *anyopaque, destOffset: Register, offset: Register, size: Register) anyerror!void,

        // Calldata Operations
        emit_native_calldataload: *const fn (ctx: *anyopaque, dst: Register, offset: Register) anyerror!void,
        emit_native_calldatasize: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,
        emit_native_calldatacopy: *const fn (ctx: *anyopaque, destOffset: Register, offset: Register, size: Register) anyerror!void,

        // Crypto
        emit_native_sha3: *const fn (ctx: *anyopaque, dst: Register, offset: Register, size: Register) anyerror!void,

        // Context reads (from JitContext)
        emit_native_address: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,
        emit_native_caller: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,
        emit_native_origin: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,
        emit_native_callvalue: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,

        // Additional context reads
        emit_native_balance: *const fn (ctx: *anyopaque, dst: Register, addr: Register) anyerror!void,
        emit_native_selfbalance: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,
        emit_native_blockhash: *const fn (ctx: *anyopaque, dst: Register, blockNum: Register) anyerror!void,
        emit_native_msize: *const fn (ctx: *anyopaque, dst: Register) anyerror!void,
        emit_native_mstore8: *const fn (ctx: *anyopaque, offset: Register, val: Register) anyerror!void,
        emit_native_codecopy: *const fn (ctx: *anyopaque, destOffset: Register, offset: Register, size: Register) anyerror!void,
        emit_native_extcodesize: *const fn (ctx: *anyopaque, dst: Register, addr: Register) anyerror!void,
        emit_native_extcodehash: *const fn (ctx: *anyopaque, dst: Register, addr: Register) anyerror!void,
        emit_native_extcodecopy: *const fn (ctx: *anyopaque, addr: Register, destOffset: Register, offset: Register, size: Register) anyerror!void,
        emit_native_returndatacopy: *const fn (ctx: *anyopaque, destOffset: Register, offset: Register, size: Register) anyerror!void,

        // Execution control
        emit_native_return: *const fn (ctx: *anyopaque, offset: Register, size: Register) anyerror!void,
        emit_native_revert: *const fn (ctx: *anyopaque, offset: Register, size: Register) anyerror!void,

        // Event logging
        emit_native_log0: *const fn (ctx: *anyopaque, offset: Register, size: Register) anyerror!void,
        emit_native_log1: *const fn (ctx: *anyopaque, offset: Register, size: Register, topic1: Register) anyerror!void,
        emit_native_log2: *const fn (ctx: *anyopaque, offset: Register, size: Register, topic1: Register, topic2: Register) anyerror!void,
        emit_native_log3: *const fn (ctx: *anyopaque, offset: Register, size: Register, topic1: Register, topic2: Register, topic3: Register) anyerror!void,
        emit_native_log4: *const fn (ctx: *anyopaque, offset: Register, size: Register, topic1: Register, topic2: Register, topic3: Register, topic4: Register) anyerror!void,

        // Native Call/Create
        emit_native_call: *const fn (ctx: *anyopaque, gas: Register, addr: Register, val: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) anyerror!void,
        emit_native_callcode: *const fn (ctx: *anyopaque, gas: Register, addr: Register, val: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) anyerror!void,
        emit_native_delegatecall: *const fn (ctx: *anyopaque, gas: Register, addr: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) anyerror!void,
        emit_native_staticcall: *const fn (ctx: *anyopaque, gas: Register, addr: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) anyerror!void,
        emit_native_create: *const fn (ctx: *anyopaque, val: Register, offset: Register, size: Register, dst: Register) anyerror!void,
        emit_native_create2: *const fn (ctx: *anyopaque, val: Register, offset: Register, size: Register, salt: Register, dst: Register) anyerror!void,

        // Legacy / Unrefactored Support
        compile_push: *const fn (ctx: *anyopaque, dst_idx: u64, value: u256) anyerror!void,
        compile_jump: *const fn (ctx: *anyopaque, target_pc: usize) anyerror!void,
        compile_jumpi: *const fn (ctx: *anyopaque, target_pc: usize, cond_idx: u64) anyerror!void,
        compile_jumpdest: *const fn (ctx: *anyopaque) anyerror!void,
        compile_pop: *const fn (ctx: *anyopaque, stack_idx: u64) anyerror!void,
        compile_swap: *const fn (ctx: *anyopaque, idx_a: u64, idx_b: u64) anyerror!void,
        compile_move: *const fn (ctx: *anyopaque, dst: u64, src: u64) anyerror!void,
    };

    pub const VirtualSlot = union(enum) {
        memory: void,
        constant: u256,
        register: Register,
    };

    pub const Register = u8; // Physical register index (e.g., X0-X30)

    pub const HoleValue = struct {
        symbol: []const u8,
        value: u64,
    };

    pub fn get_virtual_slot(self: CompilerInterface, stack_idx: usize) VirtualSlot {
        return self.vtable.get_virtual_slot(self.ptr, stack_idx);
    }

    pub fn push_virtual_constant(self: CompilerInterface, val: u256) !void {
        return self.vtable.push_virtual_constant(self.ptr, val);
    }

    pub fn push_virtual_memory(self: CompilerInterface) !void {
        return self.vtable.push_virtual_memory(self.ptr);
    }

    pub fn push_virtual_register(self: CompilerInterface, reg: Register) !void {
        return self.vtable.push_virtual_register(self.ptr, reg);
    }

    pub fn pop_virtual(self: CompilerInterface, n: usize) void {
        return self.vtable.pop_virtual(self.ptr, n);
    }

    pub fn materialize_slot(self: CompilerInterface, stack_idx: usize) !void {
        return self.vtable.materialize_slot(self.ptr, stack_idx);
    }
    pub fn sync_virtual_stack(self: CompilerInterface, stack_top: u64) !void {
        return self.vtable.sync_virtual_stack(self.ptr, stack_top);
    }

    pub fn emit_stencil(self: CompilerInterface, stencil_name: []const u8, holes: []const HoleValue) !void {
        return self.vtable.emit_stencil(self.ptr, stencil_name, holes);
    }

    pub fn emit_native_add(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_add(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_mul(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_mul(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_sub(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_sub(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_div(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_div(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_rem(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_rem(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_and(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_and(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_or(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_or(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_xor(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_xor(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_not(self: CompilerInterface, dst: Register, src1: Register) !void {
        return self.vtable.emit_native_not(self.ptr, dst, src1);
    }
    pub fn emit_native_mload(self: CompilerInterface, dst: Register, offset: Register) !void {
        return self.vtable.emit_native_mload(self.ptr, dst, offset);
    }
    pub fn emit_native_mstore(self: CompilerInterface, offset: Register, val: Register) !void {
        return self.vtable.emit_native_mstore(self.ptr, offset, val);
    }
    // Comparisons
    pub fn emit_native_lt(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_lt(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_gt(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_gt(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_eq(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_eq(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_iszero(self: CompilerInterface, dst: Register, src1: Register) !void {
        return self.vtable.emit_native_iszero(self.ptr, dst, src1);
    }
    pub fn emit_native_slt(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_slt(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_sgt(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_sgt(self.ptr, dst, src1, src2);
    }

    // Shift Operations
    pub fn emit_native_shl(self: CompilerInterface, dst: Register, val: Register, shift: Register) !void {
        return self.vtable.emit_native_shl(self.ptr, dst, val, shift);
    }
    pub fn emit_native_shr(self: CompilerInterface, dst: Register, val: Register, shift: Register) !void {
        return self.vtable.emit_native_shr(self.ptr, dst, val, shift);
    }
    pub fn emit_native_sar(self: CompilerInterface, dst: Register, val: Register, shift: Register) !void {
        return self.vtable.emit_native_sar(self.ptr, dst, val, shift);
    }
    pub fn emit_native_byte(self: CompilerInterface, dst: Register, idx: Register, val: Register) !void {
        return self.vtable.emit_native_byte(self.ptr, dst, idx, val);
    }

    // Signed Arithmetic
    pub fn emit_native_sdiv(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_sdiv(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_smod(self: CompilerInterface, dst: Register, src1: Register, src2: Register) !void {
        return self.vtable.emit_native_smod(self.ptr, dst, src1, src2);
    }
    pub fn emit_native_signextend(self: CompilerInterface, dst: Register, b: Register, x: Register) !void {
        return self.vtable.emit_native_signextend(self.ptr, dst, b, x);
    }

    // Modular Arithmetic
    pub fn emit_native_addmod(self: CompilerInterface, dst: Register, a: Register, b: Register, n: Register) !void {
        return self.vtable.emit_native_addmod(self.ptr, dst, a, b, n);
    }
    pub fn emit_native_mulmod(self: CompilerInterface, dst: Register, a: Register, b: Register, n: Register) !void {
        return self.vtable.emit_native_mulmod(self.ptr, dst, a, b, n);
    }
    pub fn emit_native_exp(self: CompilerInterface, dst: Register, base: Register, exponent: Register) !void {
        return self.vtable.emit_native_exp(self.ptr, dst, base, exponent);
    }

    // Storage Operations
    pub fn emit_native_sload(self: CompilerInterface, dst: Register, key: Register) !void {
        return self.vtable.emit_native_sload(self.ptr, dst, key);
    }
    pub fn emit_native_sstore(self: CompilerInterface, key: Register, val: Register) !void {
        return self.vtable.emit_native_sstore(self.ptr, key, val);
    }
    pub fn emit_native_tload(self: CompilerInterface, dst: Register, key: Register) !void {
        return self.vtable.emit_native_tload(self.ptr, dst, key);
    }
    pub fn emit_native_tstore(self: CompilerInterface, key: Register, val: Register) !void {
        return self.vtable.emit_native_tstore(self.ptr, key, val);
    }
    pub fn emit_native_mcopy(self: CompilerInterface, destOffset: Register, offset: Register, size: Register) !void {
        return self.vtable.emit_native_mcopy(self.ptr, destOffset, offset, size);
    }

    // Calldata Operations
    pub fn emit_native_calldataload(self: CompilerInterface, dst: Register, offset: Register) !void {
        return self.vtable.emit_native_calldataload(self.ptr, dst, offset);
    }
    pub fn emit_native_calldatasize(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_calldatasize(self.ptr, dst);
    }
    pub fn emit_native_calldatacopy(self: CompilerInterface, destOffset: Register, offset: Register, size: Register) !void {
        return self.vtable.emit_native_calldatacopy(self.ptr, destOffset, offset, size);
    }

    // Crypto
    pub fn emit_native_sha3(self: CompilerInterface, dst: Register, offset: Register, size: Register) !void {
        return self.vtable.emit_native_sha3(self.ptr, dst, offset, size);
    }

    // Context reads
    pub fn emit_native_address(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_address(self.ptr, dst);
    }
    pub fn emit_native_caller(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_caller(self.ptr, dst);
    }
    pub fn emit_native_origin(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_origin(self.ptr, dst);
    }
    pub fn emit_native_callvalue(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_callvalue(self.ptr, dst);
    }

    // Additional context reads
    pub fn emit_native_balance(self: CompilerInterface, dst: Register, addr: Register) !void {
        return self.vtable.emit_native_balance(self.ptr, dst, addr);
    }
    pub fn emit_native_selfbalance(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_selfbalance(self.ptr, dst);
    }
    pub fn emit_native_blockhash(self: CompilerInterface, dst: Register, blockNum: Register) !void {
        return self.vtable.emit_native_blockhash(self.ptr, dst, blockNum);
    }
    pub fn emit_native_msize(self: CompilerInterface, dst: Register) !void {
        return self.vtable.emit_native_msize(self.ptr, dst);
    }
    pub fn emit_native_mstore8(self: CompilerInterface, offset: Register, val: Register) !void {
        return self.vtable.emit_native_mstore8(self.ptr, offset, val);
    }
    pub fn emit_native_codecopy(self: CompilerInterface, destOffset: Register, offset: Register, size: Register) !void {
        return self.vtable.emit_native_codecopy(self.ptr, destOffset, offset, size);
    }
    pub fn emit_native_extcodesize(self: CompilerInterface, dst: Register, addr: Register) !void {
        return self.vtable.emit_native_extcodesize(self.ptr, dst, addr);
    }
    pub fn emit_native_extcodehash(self: CompilerInterface, dst: Register, addr: Register) !void {
        return self.vtable.emit_native_extcodehash(self.ptr, dst, addr);
    }
    pub fn emit_native_extcodecopy(self: CompilerInterface, addr: Register, destOffset: Register, offset: Register, size: Register) !void {
        return self.vtable.emit_native_extcodecopy(self.ptr, addr, destOffset, offset, size);
    }
    pub fn emit_native_returndatacopy(self: CompilerInterface, destOffset: Register, offset: Register, size: Register) !void {
        return self.vtable.emit_native_returndatacopy(self.ptr, destOffset, offset, size);
    }

    // Execution control
    pub fn emit_native_return(self: CompilerInterface, offset: Register, size: Register) !void {
        return self.vtable.emit_native_return(self.ptr, offset, size);
    }
    pub fn emit_native_revert(self: CompilerInterface, offset: Register, size: Register) !void {
        return self.vtable.emit_native_revert(self.ptr, offset, size);
    }

    // Event logging
    pub fn emit_native_log0(self: CompilerInterface, offset: Register, size: Register) !void {
        return self.vtable.emit_native_log0(self.ptr, offset, size);
    }
    pub fn emit_native_log1(self: CompilerInterface, offset: Register, size: Register, topic1: Register) !void {
        return self.vtable.emit_native_log1(self.ptr, offset, size, topic1);
    }
    pub fn emit_native_log2(self: CompilerInterface, offset: Register, size: Register, topic1: Register, topic2: Register) !void {
        return self.vtable.emit_native_log2(self.ptr, offset, size, topic1, topic2);
    }
    pub fn emit_native_log3(self: CompilerInterface, offset: Register, size: Register, topic1: Register, topic2: Register, topic3: Register) !void {
        return self.vtable.emit_native_log3(self.ptr, offset, size, topic1, topic2, topic3);
    }
    pub fn emit_native_log4(self: CompilerInterface, offset: Register, size: Register, topic1: Register, topic2: Register, topic3: Register, topic4: Register) !void {
        return self.vtable.emit_native_log4(self.ptr, offset, size, topic1, topic2, topic3, topic4);
    }

    pub fn emit_native_call(self: CompilerInterface, gas: Register, addr: Register, val: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) !void {
        return self.vtable.emit_native_call(self.ptr, gas, addr, val, arg_off, arg_len, ret_off, ret_len, dst);
    }
    pub fn emit_native_callcode(self: CompilerInterface, gas: Register, addr: Register, val: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) !void {
        return self.vtable.emit_native_callcode(self.ptr, gas, addr, val, arg_off, arg_len, ret_off, ret_len, dst);
    }
    pub fn emit_native_delegatecall(self: CompilerInterface, gas: Register, addr: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) !void {
        return self.vtable.emit_native_delegatecall(self.ptr, gas, addr, arg_off, arg_len, ret_off, ret_len, dst);
    }
    pub fn emit_native_staticcall(self: CompilerInterface, gas: Register, addr: Register, arg_off: Register, arg_len: Register, ret_off: Register, ret_len: Register, dst: Register) !void {
        return self.vtable.emit_native_staticcall(self.ptr, gas, addr, arg_off, arg_len, ret_off, ret_len, dst);
    }
    pub fn emit_native_create(self: CompilerInterface, val: Register, offset: Register, size: Register, dst: Register) !void {
        return self.vtable.emit_native_create(self.ptr, val, offset, size, dst);
    }
    pub fn emit_native_create2(self: CompilerInterface, val: Register, offset: Register, size: Register, salt: Register, dst: Register) !void {
        return self.vtable.emit_native_create2(self.ptr, val, offset, size, salt, dst);
    }

    pub fn compile_push(self: CompilerInterface, dst_idx: u64, value: u256) !void {
        return self.vtable.compile_push(self.ptr, dst_idx, value);
    }
    pub fn compile_jump(self: CompilerInterface, target_pc: usize) !void {
        return self.vtable.compile_jump(self.ptr, target_pc);
    }
    pub fn compile_jumpi(self: CompilerInterface, target_pc: usize, cond_idx: u64) !void {
        return self.vtable.compile_jumpi(self.ptr, target_pc, cond_idx);
    }
    pub fn compile_jumpdest(self: CompilerInterface) !void {
        return self.vtable.compile_jumpdest(self.ptr);
    }
    pub fn compile_pop(self: CompilerInterface, stack_idx: u64) !void {
        return self.vtable.compile_pop(self.ptr, stack_idx);
    }
    pub fn compile_swap(self: CompilerInterface, idx_a: u64, idx_b: u64) !void {
        return self.vtable.compile_swap(self.ptr, idx_a, idx_b);
    }
    pub fn compile_move(self: CompilerInterface, dst: u64, src: u64) !void {
        return self.vtable.compile_move(self.ptr, dst, src);
    }
};
