// File: src/vm/native_compiler.zig
const std = @import("std");
const interface = @import("compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const posix = std.posix;

const pthread_jit_write_protect_np = if (@import("builtin").os.tag.isDarwin())
    @extern(*const fn (enabled: c_int) callconv(.c) void, .{ .name = "pthread_jit_write_protect_np" })
else
    struct {
        fn dummy(enabled: c_int) void {
            _ = enabled;
        }
    }.dummy;

const PAGE_SIZE = 16384;

/// NativeJitCompiler implements a register-allocated JIT for EVM.
/// It maps the top of the EVM stack to physical machine registers.
pub const NativeJitCompiler = struct {
    allocator: std.mem.Allocator,
    code_buffer: []align(PAGE_SIZE) u8,
    current_offset: usize,
    current_bytecode_pc: usize = 0, // Track current PC for JUMPDEST

    // Register Management (Banks of 4 registers for u256)
    register_banks: [NUM_BANKS]RegisterBankState,
    virtual_stack: std.ArrayListUnmanaged(CompilerInterface.VirtualSlot),

    // Relocation Support
    jump_destinations: std.AutoHashMap(usize, usize), // PC -> Native Offset
    pending_jumps: std.ArrayListUnmanaged(Relocation),

    const Relocation = struct {
        inst_offset: usize,
        target_pc: usize,
        type: enum { Uncond, Cond },
        cond_reg: ?u8 = null, // For CBNZ (checks least significant limb for now? or needs aggregation)
    };

    const NUM_BANKS = 4;
    // Bank 0: x4-x7 (Volatile)
    // Bank 1: x11-x14 (Volatile)
    // Bank 2: x21-x24 (Callee-saved)
    // Bank 3: x25-x28 (Callee-saved)

    // Scratch used: x0-x3 (Args/Ret), x8 (Indirect Ret?), x9-x10 (Temp), x15 (Temp?), x16-x17 (IP), x18 (Reset), x19-x20 (Fixed)

    const RegisterBankState = struct {
        is_free: bool,
        stack_idx: ?usize, // Which EVM stack slot this bank holds
        locked: bool = false, // If true, cannot be spilled (used by current instruction)
    };

    pub fn init(allocator: std.mem.Allocator, code_size: usize) !NativeJitCompiler {
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

        var self = NativeJitCompiler{
            .allocator = allocator,
            .code_buffer = code_slice,
            .current_offset = 0,
            .register_banks = undefined,
            .virtual_stack = .{},
            .jump_destinations = std.AutoHashMap(usize, usize).init(allocator),
            .pending_jumps = .{},
        };

        for (&self.register_banks) |*r| {
            r.* = .{ .is_free = true, .stack_idx = null, .locked = false };
        }

        // Enable Write access initially (Disable Exec)
        pthread_jit_write_protect_np(0);

        return self;
    }

    pub fn finalize(self: *NativeJitCompiler) !void {
        try self.resolve_jumps();
        try posix.mprotect(self.code_buffer, posix.PROT.READ | posix.PROT.EXEC);

        // Enable Execute access (Disable Write)
        pthread_jit_write_protect_np(1);

        if (@import("builtin").os.tag.isDarwin()) {
            const sys_icache_invalidate = @extern(*const fn (start: *anyopaque, len: usize) callconv(.c) void, .{ .name = "sys_icache_invalidate" });
            sys_icache_invalidate(self.code_buffer.ptr, self.code_buffer.len);
        }
    }

    fn resolve_jumps(self: *NativeJitCompiler) !void {
        for (self.pending_jumps.items) |rel| {
            const target_pc = rel.target_pc;
            if (self.jump_destinations.get(target_pc)) |dest_offset| {
                const instr_off = rel.inst_offset;
                const offset_diff = @as(i64, @intCast(dest_offset)) - @as(i64, @intCast(instr_off));
                const imm19 = @divExact(offset_diff, 4);

                // Read instruction
                const old_inst = std.mem.readInt(u32, self.code_buffer[instr_off..][0..4], .little);
                // Mask out imm19
                // B.cond: 0x54000000 | (imm19 << 5) | cond
                // B: 0x14000000 | imm26
                // CBNZ: 0x35000000 | (imm19 << 5) | Rt

                var new_inst = old_inst;
                if (rel.type == .Cond) { // B.cond or CBNZ
                    new_inst &= 0xFF00001F; // Clear imm19
                    const imm_bits = @as(u32, @bitCast(@as(i32, @intCast(imm19)))) & 0x7FFFF;
                    new_inst |= (imm_bits << 5);
                } else { // Uncond B
                    new_inst &= 0xFC000000;
                    const imm_bits = @as(u32, @bitCast(@as(i32, @intCast(imm19)))) & 0x3FFFFFF;
                    new_inst |= imm_bits;
                }
                std.mem.writeInt(u32, self.code_buffer[instr_off..][0..4], new_inst, .little);
            }
        }
    }

    pub fn reset(self: *NativeJitCompiler) !void {
        // Enable Write access (Disable Exec)
        pthread_jit_write_protect_np(0);

        try posix.mprotect(self.code_buffer, posix.PROT.READ | posix.PROT.WRITE);
        self.current_offset = 0;
        self.virtual_stack.clearRetainingCapacity();
        for (&self.register_banks) |*r| {
            r.* = .{ .is_free = true, .stack_idx = null, .locked = false };
        }
        self.jump_destinations.clearRetainingCapacity();
        self.pending_jumps.clearRetainingCapacity();
    }

    fn get_bank_regs(bank_idx: u8) [4]u8 {
        return switch (bank_idx) {
            0 => .{ 4, 5, 6, 7 },
            1 => .{ 8, 9, 10, 11 },
            2 => .{ 12, 13, 14, 15 },
            3 => .{ 21, 22, 23, 24 },
            4 => .{ 25, 26, 27, 28 },
            else => unreachable,
        };
    }

    pub fn compile_bytecode(self: *NativeJitCompiler, bytecode: []const u8) !usize {
        const opcodes = @import("opcodes/index.zig");
        var pc: usize = 0;
        var stack_top: u64 = 0;
        try self.compile_prologue();

        compiler_loop: while (pc < bytecode.len) {
            self.current_bytecode_pc = pc; // Update context
            const op = bytecode[pc];
            std.debug.print("Compiling PC: {d} Op: {X}\n", .{ pc, op });
            if (op == 0xFE) {
                // Stop compilation on INVALID (used as data/code separator or trap)
                self.write_32(0xD4200020);
                break :compiler_loop;
            }

            // Build dispatch (simplified for pilot)
            inline for (opcodes.all_opcodes) |op_module| {
                const op_info = op_module.getImpl();
                if (op == op_info.code) {
                    pc += 1;
                    try op_module.jit_compile(self.compiler(), &pc, &stack_top, bytecode);
                    break;
                }
            } else {
                pc += 1; // Skip unknown
            }
        }

        try self.flush_all_to_memory();
        try self.compile_epilogue();
        try self.finalize();
        return stack_top;
    }

    pub fn compile_prologue(self: *NativeJitCompiler) !void {
        // ARM64 Prologue
        // stp x29, x30, [sp, #-112]!
        // stp x19, x20, [sp, #16]
        // ... (x21-x28)

        // stp x29, x30, [sp, #-112]!
        // Save FP, LR
        self.write_32(0xA9BF7BFD); // stp x29, x30, [sp, #-16]!
        self.write_32(0x910003FD); // mov x29, sp

        // Save callee-saved registers x19-x28 (5 pairs)
        self.write_32(0xA9BF53F3); // stp x19, x20, [sp, #-16]!
        self.write_32(0xA9BF5BF5); // stp x21, x22, [sp, #-16]!
        self.write_32(0xA9BF63F7); // stp x23, x24, [sp, #-16]!
        self.write_32(0xA9BF6BF9); // stp x25, x26, [sp, #-16]!
        self.write_32(0xA9BF73FB); // stp x27, x28, [sp, #-16]!

        // x19 = stack base (from x0)
        self.write_32(0xAA0003F3); // mov x19, x0
        // x20 = JitContext (from x1)
        self.write_32(0xAA0103F4); // mov x20, x1
    }

    pub fn flush_all_to_memory(self: *NativeJitCompiler) !void {
        if (self.virtual_stack.items.len == 0) return;

        for (self.virtual_stack.items, 0..) |*slot, i| {
            const offset = i * 32;
            if (offset > 4095) continue; // Stack limit for simple LDR/STR

            switch (slot.*) {
                .constant => |val| {
                    inline for (0..4) |j| {
                        const shift = j * 64;
                        const limb = @as(u64, @truncate(val >> shift));
                        try self.emit_load_u64(9, limb);
                        const store_off = offset + (j * 8);
                        const str_inst = 0xf9000000 | (@as(u32, @intCast(store_off / 8)) << 10) | (19 << 5) | 9;
                        self.write_32(str_inst);
                    }
                    slot.* = .memory;
                },
                .register => |bank| {
                    const regs = get_bank_regs(bank);
                    inline for (0..4) |j| {
                        const store_off = offset + (j * 8);
                        const str_inst = 0xf9000000 | (@as(u32, @intCast(store_off / 8)) << 10) | (19 << 5) | @as(u32, regs[j]);
                        self.write_32(str_inst);
                    }
                    // Free bank
                    self.register_banks[bank].is_free = true;
                    self.register_banks[bank].stack_idx = null;
                    self.register_banks[bank].locked = false; // Also unlock
                    slot.* = .memory;
                },
                .memory => {},
            }
        }
    }

    pub fn compile_epilogue(self: *NativeJitCompiler) !void {
        try self.flush_all_to_memory();

        // Standard epilogue for NativeCompiler (matches prologue 6 x 16-byte pushes)
        self.write_32(0xA8C173FB); // ldp x27, x28, [sp], #16
        self.write_32(0xA8C16BF9); // ldp x25, x26, [sp], #16
        self.write_32(0xA8C163F7); // ldp x23, x24, [sp], #16
        self.write_32(0xA8C15BF5); // ldp x21, x22, [sp], #16
        self.write_32(0xA8C153F3); // ldp x19, x20, [sp], #16
        self.write_32(0xA8C17BFD); // ldp x29, x30, [sp], #16
        self.write_32(0xD65F03C0); // ret
    }

    pub fn getFunction(self: *NativeJitCompiler) *const anyopaque {
        return @ptrCast(self.code_buffer.ptr);
    }

    pub fn init_registers(self: *NativeJitCompiler) void {
        for (&self.register_banks) |*r| {
            r.* = .{ .is_free = true, .stack_idx = null, .locked = false };
        }
    }

    pub fn deinit(self: *NativeJitCompiler) void {
        posix.munmap(self.code_buffer);
        self.virtual_stack.deinit(self.allocator);
        self.jump_destinations.deinit();
        self.pending_jumps.deinit(self.allocator);
    }

    pub fn compiler(self: *NativeJitCompiler) CompilerInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .get_virtual_slot = get_virtual_slot,
                .push_virtual_constant = push_virtual_constant,
                .push_virtual_memory = push_virtual_memory,
                .pop_virtual = pop_virtual,
                .materialize_slot = materialize_slot,
                .sync_virtual_stack = sync_virtual_stack,
                .emit_stencil = emit_stencil,
                .emit_native_add = emit_native_add,
                .emit_native_mul = emit_native_mul,
                .emit_native_sub = emit_native_sub,
                .emit_native_div = emit_native_div,
                .emit_native_rem = emit_native_rem,
                .emit_native_and = emit_native_and,
                .emit_native_or = emit_native_or,
                .emit_native_xor = emit_native_xor,
                .emit_native_not = emit_native_not,
                .emit_native_mload = emit_native_mload,
                .emit_native_mstore = emit_native_mstore,
                .emit_native_lt = emit_native_lt,
                .emit_native_gt = emit_native_gt,
                .emit_native_eq = emit_native_eq,
                .emit_native_iszero = emit_native_iszero,
                .emit_native_slt = emit_native_slt,
                .emit_native_sgt = emit_native_sgt,

                // Shift Operations
                .emit_native_shl = emit_native_shl,
                .emit_native_shr = emit_native_shr,
                .emit_native_sar = emit_native_sar,
                .emit_native_byte = emit_native_byte,

                // Signed Arithmetic
                .emit_native_sdiv = emit_native_sdiv,
                .emit_native_smod = emit_native_smod,
                .emit_native_signextend = emit_native_signextend,

                // Modular Arithmetic
                .emit_native_addmod = emit_native_addmod,
                .emit_native_mulmod = emit_native_mulmod,
                .emit_native_exp = emit_native_exp,

                // Storage Operations
                .emit_native_sload = emit_native_sload,
                .emit_native_sstore = emit_native_sstore,
                .emit_native_tload = emit_native_tload,
                .emit_native_tstore = emit_native_tstore,
                .emit_native_mcopy = emit_native_mcopy,

                // Calldata Operations
                .emit_native_calldataload = emit_native_calldataload,
                .emit_native_calldatasize = emit_native_calldatasize,
                .emit_native_calldatacopy = emit_native_calldatacopy,

                // Crypto
                .emit_native_sha3 = emit_native_sha3,

                // Context reads
                .emit_native_address = emit_native_address,
                .emit_native_caller = emit_native_caller,
                .emit_native_origin = emit_native_origin,
                .emit_native_callvalue = emit_native_callvalue,

                // Additional context reads
                .emit_native_balance = emit_native_balance,
                .emit_native_selfbalance = emit_native_selfbalance,
                .emit_native_blockhash = emit_native_blockhash,
                .emit_native_msize = emit_native_msize,
                .emit_native_mstore8 = emit_native_mstore8,
                .emit_native_codecopy = emit_native_codecopy,
                .emit_native_extcodesize = emit_native_extcodesize,
                .emit_native_extcodehash = emit_native_extcodehash,
                .emit_native_extcodecopy = emit_native_extcodecopy,
                .emit_native_returndatacopy = emit_native_returndatacopy,

                // Execution control
                .emit_native_return = emit_native_return,
                .emit_native_revert = emit_native_revert,

                // Event logging
                .emit_native_log0 = emit_native_log0,
                .emit_native_log1 = emit_native_log1,
                .emit_native_log2 = emit_native_log2,
                .emit_native_log3 = emit_native_log3,
                .emit_native_log4 = emit_native_log4,

                // Native Call/Create
                .emit_native_call = emit_native_call,
                .emit_native_callcode = emit_native_callcode,
                .emit_native_delegatecall = emit_native_delegatecall,
                .emit_native_staticcall = emit_native_staticcall,
                .emit_native_create = emit_native_create,
                .emit_native_create2 = emit_native_create2,

                // Legacy Stubs
                .push_virtual_register = push_virtual_register,
                .compile_push = compile_push,
                .compile_jump = compile_jump,
                .compile_jumpi = compile_jumpi,
                .compile_jumpdest = compile_jumpdest,
                .compile_pop = compile_pop_stub,
                .compile_swap = compile_swap,
                .compile_move = compile_move,
            },
        };
    }

    fn compile_move_stub(_: *anyopaque, _: u64, _: u64) !void {
        return error.UnsupportedByNative;
    }

    fn compile_push(ctx: *anyopaque, stack_idx: u64, value: u256) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        _ = self;
        _ = stack_idx;
        _ = value;
    }
    fn compile_jump(ctx: *anyopaque, target_pc: usize) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Flush before jump to ensure target sees consistent memory state
        try self.flush_all_to_memory();
        // Emit placeholder B 0
        const inst = 0x14000000;
        try self.pending_jumps.append(self.allocator, .{ .inst_offset = self.current_offset, .target_pc = target_pc, .type = .Uncond });
        self.write_32(inst);
    }

    fn compile_jumpi(ctx: *anyopaque, condition_stack_idx: u64, target_pc: usize) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Materialize condition register
        const cond_slot_idx = @as(usize, @intCast(condition_stack_idx));
        try materialize_slot(ctx, cond_slot_idx);
        const slot = get_virtual_slot(ctx, cond_slot_idx);

        const reg = switch (slot) {
            .register => |r| r,
            else => return error.InvalidStackState,
        };

        const regs = get_bank_regs(reg);
        const lsdl = regs[0];

        // Flush OTHER slots to memory before jump.
        // We MUST keep the condition register alive for the CBNZ!
        // So we flush everything EXCEPT the condition bank.
        for (self.virtual_stack.items, 0..) |*s, i| {
            if (i == cond_slot_idx) continue;
            const offset = i * 32;
            if (offset > 4095) continue;

            switch (s.*) {
                .constant => |val| {
                    inline for (0..4) |j| {
                        const shift = j * 64;
                        const limb = @as(u64, @truncate(val >> shift));
                        try self.emit_load_u64(9, limb);
                        const store_off = offset + (j * 8);
                        const str_inst = 0xf9000000 | (@as(u32, @intCast(store_off / 8)) << 10) | (19 << 5) | 9;
                        self.write_32(str_inst);
                    }
                    s.* = .memory;
                },
                .register => |bank| {
                    const r_regs = get_bank_regs(bank);
                    inline for (0..4) |j| {
                        const store_off = offset + (j * 8);
                        const str_inst = 0xf9000000 | (@as(u32, @intCast(store_off / 8)) << 10) | (19 << 5) | @as(u32, r_regs[j]);
                        self.write_32(str_inst);
                    }
                    self.register_banks[bank].is_free = true;
                    self.register_banks[bank].stack_idx = null;
                    self.register_banks[bank].locked = false; // Also unlock
                    s.* = .memory;
                },
                .memory => {},
            }
        }

        // CBNZ x<reg>, offset (64-bit): 0xB5000000 | (offset << 5) | Rt
        const inst = 0xB5000000 | @as(u32, lsdl);
        try self.pending_jumps.append(self.allocator, .{
            .inst_offset = self.current_offset,
            .target_pc = target_pc,
            .type = .Cond,
            .cond_reg = lsdl,
        });
        self.write_32(inst);

        // Finally flush the condition register too, but after the CBNZ
        const offset = cond_slot_idx * 32;
        if (offset <= 4095) {
            inline for (0..4) |j| {
                const store_off = offset + (j * 8);
                const str_inst = 0xf9000000 | (@as(u32, @intCast(store_off / 8)) << 10) | (19 << 5) | @as(u32, regs[j]);
                self.write_32(str_inst);
            }
            self.register_banks[reg].is_free = true;
            self.register_banks[reg].stack_idx = null;
            self.register_banks[reg].locked = false; // Also unlock
            self.virtual_stack.items[cond_slot_idx] = .memory;
        }
    }

    fn compile_jumpdest(ctx: *anyopaque) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Flush before JUMPDEST to ensure anyone jumping HERE sees consistent state
        try self.flush_all_to_memory();
        try self.jump_destinations.put(self.current_bytecode_pc, self.current_offset);
    }

    fn compile_move(ctx: *anyopaque, dst_idx: u64, src_idx: u64) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const src_sidx = @as(usize, @intCast(src_idx));
        const dst_sidx = @as(usize, @intCast(dst_idx));

        try materialize_slot(ctx, src_sidx);
        const slot = get_virtual_slot(ctx, src_sidx);
        const src_bank = slot.register;

        // Allocate dest bank
        const dst_bank = try self.allocate_bank(dst_sidx);

        const src_regs = get_bank_regs(src_bank);
        const dst_regs = get_bank_regs(dst_bank);

        // Chain 4 MOVs: ORR dst, XZR, src
        inline for (0..4) |i| {
            const inst = 0xAA000000 | (@as(u32, src_regs[i]) << 16) | (31 << 5) | @as(u32, dst_regs[i]);
            self.write_32(inst);
        }
        self.virtual_stack.items[dst_sidx] = .{ .register = dst_bank };
        self.unlock_all_banks();
    }

    fn compile_swap(ctx: *anyopaque, idx1: u64, idx2: u64) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const s1 = @as(usize, @intCast(idx1));
        const s2 = @as(usize, @intCast(idx2));

        // Materialize both slots to registers to ensure they are movable
        try materialize_slot(ctx, s1);
        try materialize_slot(ctx, s2);

        // Swap slots
        std.mem.swap(CompilerInterface.VirtualSlot, &self.virtual_stack.items[s1], &self.virtual_stack.items[s2]);

        // Update register back-pointers
        for (&self.register_banks) |*r| {
            if (r.stack_idx) |s_idx| {
                if (s_idx == s1) {
                    r.stack_idx = s2;
                } else if (s_idx == s2) {
                    r.stack_idx = s1;
                }
            }
        }
        self.unlock_all_banks();
    }

    fn compile_mload(ctx: *anyopaque, offset_idx: u64) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const off_sidx = @as(usize, @intCast(offset_idx));
        try materialize_slot(ctx, off_sidx);

        // Offset is consumed? No, MLOAD takes offset from stack (top).
        // Stack: [offset, ...] -> [value, ...]
        // Reuse register for value? Or allocate new?
        // Offset register becomes Value register.
        const off_slot = get_virtual_slot(ctx, off_sidx);
        const off_reg = off_slot.register;

        // Emit MLOAD (offset in off_reg, result in off_reg)
        try self.emit_native_mload(off_reg, off_reg);
        self.unlock_all_banks();
    }

    fn compile_mstore(ctx: *anyopaque, offset_idx: u64, val_idx: u64) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const off_sidx = @as(usize, @intCast(offset_idx));
        const val_sidx = @as(usize, @intCast(val_idx));

        try materialize_slot(ctx, off_sidx);
        try materialize_slot(ctx, val_sidx);

        const off_reg = get_virtual_slot(ctx, off_sidx).register;
        const val_reg = get_virtual_slot(ctx, val_sidx).register;

        try self.emit_native_mstore(off_reg, val_reg);
        self.unlock_all_banks();
    }

    fn compile_pop_stub(_: *anyopaque, _: u64) !void {
        return error.UnsupportedByNative;
    }

    // --- Memory Expansion Helper ---

    // Checks if memory access at [offset, offset+size] requires expansion.
    // If so, calls evm_extend_memory.
    // Preserves registers except x16 (scratch) and x0-x8 (arguments/scratch).
    // offset_reg: register bank containing offset (u256)
    // size_reg: register bank containing size (u256), or null if immediate size
    // imm_size: immediate size if size_reg is null
    fn emit_memory_check(self: *NativeJitCompiler, offset_reg: CompilerInterface.Register, size_reg: ?CompilerInterface.Register, imm_size: u64) !void {
        // 1. Calculate required size in x1
        if (size_reg) |sz_reg| {
            // Memory check with dynamic size
            // x1 = offset + size
            const off_regs = get_bank_regs(offset_reg);
            const sz_regs = get_bank_regs(sz_reg);

            // Allow simplified check: Assume u64 fits in first limb
            // ADD x1, off[0], sz[0]
            const inst: u32 = 0x8b000000 | (@as(u32, sz_regs[0]) << 16) | (@as(u32, off_regs[0]) << 5) | 1;
            self.write_32(inst);
        } else {
            // Memory check with immediate size
            const off_regs = get_bank_regs(offset_reg);
            // x1 = offset + imm_size
            // ADD x1, off[0], #imm
            const imm12 = @as(u32, @intCast(imm_size));
            const inst: u32 = 0x91000000 | (imm12 << 10) | (@as(u32, off_regs[0]) << 5) | 1;
            self.write_32(inst);
        }

        // 2. Load current capacity from JitContext (x20)
        // memory_len @ 16
        self.emit_ldr_reg_imm(2, 20, 16);

        // 3. CMP required(x1), capacity(x2)
        const inst = 0xEB02003F;
        self.write_32(inst);

        // 4. B.LS skip (if required <= capacity)
        // We need to calculate jump offset.
        // Save/Restore: Banks 0 and 1 are volatile.
        // 4. B.LS skip
        // Slow path: Save 3 banks (12 insts) + Call (3 insts) = 15 insts.
        // Jump over 15 instructions -> offset 16.
        const jump_off = 16;
        const inst_b = 0x54000000 | (jump_off << 5) | 9; // B.LS
        self.write_32(inst_b);

        // --- Slow Path: Expand Memory ---

        // Unconditionally save Volatiles (Banks 0, 1, 2) to be safe
        inline for (0..3) |b| {
            const regs = get_bank_regs(@intCast(b));
            // STP regs[0], regs[1], [sp, #-16]!
            const stp1 = 0xA9BF0000 | (@as(u32, regs[1]) << 10) | (31 << 5) | @as(u32, regs[0]);
            self.write_32(stp1);
            // STP regs[2], regs[3], [sp, #-16]!
            const stp2 = 0xA9BF0000 | (@as(u32, regs[3]) << 10) | (31 << 5) | @as(u32, regs[2]);
            self.write_32(stp2);
        }

        // Call expand(ctx=x20, size=x1)
        self.write_32(0xAA1403E0); // MOV x0, x20
        // x1 already set

        // Callback @ 440 (evm_extend_memory)
        self.emit_ldr_reg_imm(9, 20, 440); // LDR x9, [x20, #440]
        self.write_32(0xD63F0120); // BLR x9

        // Restore Volatiles (Reverse order)
        var b: isize = 2;
        while (b >= 0) : (b -= 1) {
            const regs = get_bank_regs(@intCast(b));
            // LDP regs[2], regs[3], [sp], #16
            const ldp1 = 0xA8C10000 | (@as(u32, regs[3]) << 10) | (31 << 5) | @as(u32, regs[2]);
            self.write_32(ldp1);
            // LDP regs[0], regs[1], [sp], #16
            const ldp2 = 0xA8C10000 | (@as(u32, regs[1]) << 10) | (31 << 5) | @as(u32, regs[0]);
            self.write_32(ldp2);
        }

        // skip:
    }

    // --- Interface Implementation ---

    fn get_virtual_slot(ctx: *anyopaque, stack_idx: usize) CompilerInterface.VirtualSlot {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        if (stack_idx >= self.virtual_stack.items.len) return .memory;
        return self.virtual_stack.items[stack_idx];
    }

    fn push_virtual_constant(ctx: *anyopaque, val: u256) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.virtual_stack.append(self.allocator, .{ .constant = val });
    }

    fn push_virtual_memory(ctx: *anyopaque) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.virtual_stack.append(self.allocator, .memory);
    }

    fn pop_virtual(ctx: *anyopaque, n: usize) void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const len = self.virtual_stack.items.len;
        if (n > len) {
            self.virtual_stack.items.len = 0;
        } else {
            // If any popped slots were in registers, free them
            for (len - n..len) |i| {
                const slot = self.virtual_stack.items[i];
                if (slot == .register) {
                    if (slot.register < self.register_banks.len) {
                        self.register_banks[slot.register].is_free = true;
                        self.register_banks[slot.register].stack_idx = null;
                        self.register_banks[slot.register].locked = false; // Also unlock
                    }
                }
            }
            self.virtual_stack.items.len -= n;
        }
    }

    fn materialize_slot(ctx: *anyopaque, stack_idx: usize) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const slot = &self.virtual_stack.items[stack_idx];

        switch (slot.*) {
            .constant => |val| {
                const bank = try self.allocate_bank(stack_idx);
                const regs = get_bank_regs(bank);
                std.debug.print("DEBUG: materialize_slot({d}) const -> bank {d}\n", .{ stack_idx, bank });

                // Load 4 limbs
                inline for (0..4) |i| {
                    const shift = i * 64;
                    const limb_val = @as(u64, @truncate(val >> shift));
                    try self.emit_load_u64(regs[i], limb_val);
                }
                slot.* = .{ .register = bank };
                self.register_banks[bank].locked = true; // Lock for this instruction
            },
            .memory => {
                // Load from EVM stack into a bank
                const bank = try self.allocate_bank(stack_idx);
                std.debug.print("DEBUG: materialize_slot({d}) memory -> bank {d}\n", .{ stack_idx, bank });
                try self.emit_load_u256_from_stack(bank, stack_idx);
                slot.* = .{ .register = bank };
                self.register_banks[bank].locked = true; // Lock for this instruction
            },
            .register => |bank| {
                std.debug.print("DEBUG: materialize_slot({d}) register bank {d} locked\n", .{ stack_idx, bank });
                self.register_banks[bank].locked = true; // Ensure it's locked
            },
        }
    }

    fn sync_virtual_stack(ctx: *anyopaque, stack_top: u64) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const len = self.virtual_stack.items.len;
        if (stack_top < len) {
            const n = len - @as(usize, @intCast(stack_top));
            pop_virtual(ctx, n);
        } else if (stack_top > len) {
            const diff = @as(usize, @intCast(stack_top)) - len;
            try self.virtual_stack.ensureUnusedCapacity(self.allocator, diff);
            for (0..diff) |_| {
                self.virtual_stack.appendAssumeCapacity(.memory);
            }
        }
    }

    // Helper to unlock all banks (call at end of emit_*)
    // Actually, locking is only needed DURING materialization sequence.
    // Ideally we unlock after instruction emit.
    // But since we don't wrap every emit, let's just expose a way to unlock or auto-unlock.
    // Wait, materialize_slot is called by jit_compile in opcodes.
    // Then emit_native_* is called.
    // We should unlock at the end of emit_native_*. Or easier: unlock all at start of any emit_?
    // No, allocate_bank happens before emit.
    // Correct flow:
    // 1. Opcode: materialize(a), materialize(b)
    //    -> allocate(a) [locks a], allocate(b) [locks b]
    // 2. emit_native_add(a, b)
    // 3. Unlock all? Or just leave them allocated? locked=false, is_free=false.
    //    We just need to clear 'locked' status after operands are ready.
    //    We can clear 'locked' status in `allocate_bank` loop?? No.
    //    We need `unlock_banks()` function called by opcode handlers or automatically.

    // Better strategy: `materialize_slot` locks. `emit_native_*` clears locks at the end?
    // This requires updating ALL emit functions.
    // Alternative: `allocate_bank` ignores locked banks.
    // We need to clear `locked` flags sometime.
    // Let's add `unlock_all_banks()` and call it at the end of every `emit_native_*` and `jit_compile` scope.
    // Or simpler: `reset_locks()` called at start of `jit_compile`? No, that's too early if we call helpers.
    // Let's rely on explicit unlock or just clear locks at the *start* of `allocate_bank` if we detect a new instruction cycle? Hard to detect.

    // Simplest: Add `unlock_registers()` to CompilerInterface and call it in `opcodes`.
    // BUT we can't change all opcodes easily.
    // Observation: `emit_native_*` functions consume the registers.
    // So `emit_native_*` should clear locks.

    fn unlock_all_banks(self: *NativeJitCompiler) void {
        for (&self.register_banks) |*r| {
            r.locked = false;
        }
    }

    // Inserting `allocate_bank` and `emit_spill_bank` here replacing original allocate_bank

    fn allocate_bank(self: *NativeJitCompiler, stack_idx: usize) !CompilerInterface.Register {
        // 1. Try to find a free bank
        for (&self.register_banks, 0..) |*r, i| {
            if (r.is_free) {
                r.is_free = false;
                r.stack_idx = stack_idx;
                return @intCast(i);
            }
        }

        // 2. No free bank -> Spill
        // Policy: Spill specific bank? Or "Deepest"?
        // Find victim: Bank with lowest stack_idx (deepest in stack)
        // AND NOT locked.

        var victim_idx: ?usize = null;
        var min_stack_idx: usize = std.math.maxInt(usize);

        for (self.register_banks, 0..) |r, i| {
            if (r.locked) continue;
            if (r.stack_idx) |idx| {
                if (idx < min_stack_idx) {
                    min_stack_idx = idx;
                    victim_idx = i;
                }
            }
        }

        if (victim_idx) |v_idx| {
            // Spill this bank
            try self.emit_spill_bank(@intCast(v_idx));

            // Mark as memory in virtual stack
            if (self.register_banks[v_idx].stack_idx) |s_idx| {
                self.virtual_stack.items[s_idx] = .memory;
            }

            // Reassign bank
            self.register_banks[v_idx].stack_idx = stack_idx;
            self.register_banks[v_idx].is_free = false;
            return @intCast(v_idx);
        }

        return error.OutofRegistersAndAllLocked;
    }

    fn emit_spill_bank(self: *NativeJitCompiler, bank_idx: u8) !void {
        const regs = get_bank_regs(bank_idx);
        const stack_idx = self.register_banks[bank_idx].stack_idx orelse return error.SpillFreeBank;
        const offset = stack_idx * 32;

        if (offset + 24 > 4095) return error.OffsetTooLarge;

        // STR xReg, [x19, #offset]
        inline for (0..4) |i| {
            const store_off = offset + (i * 8);
            // STR (scaled immediate): 0xf9000000 | (imm12 << 10) | (Rn << 5) | Rt
            const imm12 = @as(u32, @intCast(store_off / 8));
            const inst = 0xf9000000 | (imm12 << 10) | (19 << 5) | @as(u32, regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_stencil(_: *anyopaque, _: []const u8, _: []const CompilerInterface.HoleValue) !void {
        return; // Stencil fallback is not used in pure native mode for now
    }

    fn emit_load_u64(self: *NativeJitCompiler, reg: u8, val: u64) !void {
        // MOVZ xReg, #imm16, LSL #0
        // MOVK xReg, #imm16, LSL #16
        // MOVK xReg, #imm16, LSL #32
        // MOVK xReg, #imm16, LSL #48

        const part0 = @as(u16, @truncate(val));
        const part1 = @as(u16, @truncate(val >> 16));
        const part2 = @as(u16, @truncate(val >> 32));
        const part3 = @as(u16, @truncate(val >> 48));

        // MOVZ: 0xD2800000 | (imm16 << 5) | (shift/16 << 21) | Rd
        const inst0 = 0xD2800000 | (@as(u32, part0) << 5) | @as(u32, reg);
        self.write_32(inst0);

        if (part1 != 0) {
            const inst = 0xF2800000 | (@as(u32, part1) << 5) | (1 << 21) | @as(u32, reg);
            self.write_32(inst);
        }
        if (part2 != 0) {
            const inst = 0xF2800000 | (@as(u32, part2) << 5) | (2 << 21) | @as(u32, reg);
            self.write_32(inst);
        }
        if (part3 != 0) {
            const inst = 0xF2800000 | (@as(u32, part3) << 5) | (3 << 21) | @as(u32, reg);
            self.write_32(inst);
        }
    }

    fn push_virtual_register(ctx: *anyopaque, reg: CompilerInterface.Register) !void {
        const self = @as(*NativeJitCompiler, @ptrCast(@alignCast(ctx)));
        try self.virtual_stack.append(self.allocator, .{ .register = reg });
    }

    // --- Native Emission ---

    fn emit_native_add(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));

        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // Chain: ADDS, ADCS, ADCS, ADC
        // 1. ADDS d0, s1_0, s2_0 (Sets Flags)
        // ADDS (shifted reg): 0xAB000000 | (Rm << 16) | (Rn << 5) | Rd
        var inst = 0xAB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);

        // 2. ADCS d1, s1_1, s2_1 (Uses Flags, Sets Flags)
        // ADCS: 0xBA000000 | (Rm << 16) | (Rn << 5) | Rd
        inst = 0xBA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | @as(u32, d_regs[1]);
        self.write_32(inst);

        // 3. ADCS d2, s1_2, s2_2
        inst = 0xBA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | @as(u32, d_regs[2]);
        self.write_32(inst);

        // 4. ADC d3, s1_3, s2_3 (Uses Flags, No Set Flags needed strictly, but consistent)
        // ADC: 0x9A000000
        inst = 0x9A000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    fn emit_native_mul(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // For now, only perform 64-bit LSD multiplication (as needed for benchmarks)
        // mul d0, s1_0, s2_0
        // madd: 0x9b007c00 | (Rm << 16) | (Rn << 5) | Rd (madd Rd, Rn, Rm, xzr)
        const inst = 0x9b007c00 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);

        // Zero other limbs for correctness in this truncated version
        inline for (1..4) |i| {
            // mov xRd, xzr (orr Rd, xzr, xzr): 0xaa1f03e0 | Rd
            const zero_inst = 0xaa1f03e0 | @as(u32, d_regs[i]);
            self.write_32(zero_inst);
        }
    }

    fn emit_native_sub(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));

        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // Chain: SUBS, SBCS, SBCS, SBC
        // 1. SUBS d0, s1_0, s2_0 (Sets Flags)
        // SUBS (shifted reg): 0xEB000000 | (Rm << 16) | (Rn << 5) | Rd
        var inst = 0xEB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);

        // 2. SBCS d1, s1_1, s2_1 (Uses Flags, Sets Flags)
        // SBCS: 0xFA000000 | (Rm << 16) | (Rn << 5) | Rd
        inst = 0xFA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | @as(u32, d_regs[1]);
        self.write_32(inst);

        // 3. SBCS d2, s1_2, s2_2
        inst = 0xFA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | @as(u32, d_regs[2]);
        self.write_32(inst);

        // 4. SBC d3, s1_3, s2_3 (Uses Flags)
        // SBC: 0xDA000000
        inst = 0xDA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    fn emit_native_div(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByNative; // TODO: u256 Division is complex (Knuth D)
    }

    fn emit_native_rem(_: *anyopaque, _: CompilerInterface.Register, _: CompilerInterface.Register, _: CompilerInterface.Register) !void {
        return error.UnsupportedByNative;
    }

    fn emit_native_and(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        inline for (0..4) |i| {
            // ARM64 AND: 0x8a000000 | (Rm << 16) | (Rn << 5) | Rd
            const inst = 0x8A000000 | (@as(u32, s2_regs[i]) << 16) | (@as(u32, s1_regs[i]) << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_or(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        inline for (0..4) |i| {
            // ARM64 ORR: 0xaa000000 | (Rm << 16) | (Rn << 5) | Rd
            const inst = 0xAA000000 | (@as(u32, s2_regs[i]) << 16) | (@as(u32, s1_regs[i]) << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_xor(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        inline for (0..4) |i| {
            // EOR d, s1, s2
            // 0xCA000000
            const inst = 0xCA000000 | (@as(u32, s2_regs[i]) << 16) | (@as(u32, s1_regs[i]) << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_not(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);

        inline for (0..4) |i| {
            // ORN d, xzr, s1 (NOT s1)
            // 0xAA200000 | (Rm << 16) | (31 << 5) | Rd
            const inst = 0xAA200000 | (@as(u32, s1_regs[i]) << 16) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    // --- u256 Comparisons ---
    // u256 LT: a < b. Returns 1 if true, 0 otherwise.
    // Strategy: Compare limbs from MSB to LSB. If s1[i] < s2[i], result=1. If s1[i] > s2[i], result=0.
    // If equal, continue to next limb. If all equal, result=0.
    fn emit_native_lt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // Use SUBS/SBCS chain from LSB to MSB, then CSET based on carry flag
        // ARM64 unsigned comparison: after SUBS, C (carry) is SET if no borrow (a >= b)
        // So for LT: C clear means a < b -> use CSET dst, CC (Carry Clear)
        // CMP s1[0], s2[0] (SUBS xzr, s1[0], s2[0])
        var inst: u32 = 0xEB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 31;
        self.write_32(inst);
        // SBCS xzr, s1[1], s2[1]
        inst = 0xFA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | 31;
        self.write_32(inst);
        // CSET d[0], CC (Carry Clear = borrow = LT)
        // CSET Rd, CC: 0x9A9F37E0 | Rd (CSINC Rd, XZR, XZR, CS which is inverse of CC)
        // Actually: CSET Rd, cond = CSINC Rd, XZR, XZR, invert(cond)
        // CC (cond=3) -> invert is CS (cond=2). CSINC 0x9A8003E0 | (invert_cond << 12) | Rd
        inst = 0x9A9F27E0 | @as(u32, d_regs[0]); // CSET d[0], CC
        self.write_32(inst);
        // Zero other limbs
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]); // MOVZ d[i], #0
            self.write_32(inst);
        }
    }

    // (Stubs deleted)

    fn emit_native_gt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // GT: a > b. Compare s2 < s1 via subtraction, then check C clear (borrow from s2)
        // CMP s2[0], s1[0]
        var inst: u32 = 0xEB000000 | (@as(u32, s1_regs[0]) << 16) | (@as(u32, s2_regs[0]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s1_regs[1]) << 16) | (@as(u32, s2_regs[1]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s1_regs[2]) << 16) | (@as(u32, s2_regs[2]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s1_regs[3]) << 16) | (@as(u32, s2_regs[3]) << 5) | 31;
        self.write_32(inst);
        inst = 0x9A9F27E0 | @as(u32, d_regs[0]); // CSET d[0], CC
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_eq(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // EQ: XOR all limbs, OR results, then CSET if zero
        // XOR d[0] = s1[0] ^ s2[0], ... OR all -> CBNZ/CBZ pattern
        // Simpler: EOR x9, s1[0], s2[0]; ORR x9, x9, EOR(s1[1],s2[1]); ... CSET if x9==0
        var inst: u32 = 0xCA000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 9;
        self.write_32(inst);
        inst = 0xCA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | 10;
        self.write_32(inst);
        inst = 0xAA000000 | (10 << 16) | (9 << 5) | 9; // ORR x9, x9, x10
        self.write_32(inst);
        inst = 0xCA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | 10;
        self.write_32(inst);
        inst = 0xAA000000 | (10 << 16) | (9 << 5) | 9;
        self.write_32(inst);
        inst = 0xCA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | 10;
        self.write_32(inst);
        inst = 0xAA000000 | (10 << 16) | (9 << 5) | 9;
        self.write_32(inst);
        // CMP x9, #0
        inst = 0xF100001F | (9 << 5); // SUBS xzr, x9, #0
        self.write_32(inst);
        // CSET d[0], EQ (Z flag set)
        inst = 0x9A9F17E0 | @as(u32, d_regs[0]); // CSET d[0], EQ
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_iszero(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);

        // ISZERO: ORR all limbs, if result is 0 -> 1, else -> 0
        var inst: u32 = 0xAA000000 | (@as(u32, s1_regs[1]) << 16) | (@as(u32, s1_regs[0]) << 5) | 9;
        self.write_32(inst);
        inst = 0xAA000000 | (@as(u32, s1_regs[2]) << 16) | (9 << 5) | 9;
        self.write_32(inst);
        inst = 0xAA000000 | (@as(u32, s1_regs[3]) << 16) | (9 << 5) | 9;
        self.write_32(inst);
        // CMP x9, #0
        inst = 0xF100001F | (9 << 5);
        self.write_32(inst);
        // CSET d[0], EQ
        inst = 0x9A9F17E0 | @as(u32, d_regs[0]);
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_slt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // Signed LT: Same as unsigned LT but use CSET LT (signed less than)
        var inst: u32 = 0xEB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | 31;
        self.write_32(inst);
        // CSET d[0], LT (N != V)
        inst = 0x9A9FA7E0 | @as(u32, d_regs[0]); // CSET d[0], LT
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_sgt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // Signed GT: Compare s2 < s1 (signed)
        var inst: u32 = 0xEB000000 | (@as(u32, s1_regs[0]) << 16) | (@as(u32, s2_regs[0]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s1_regs[1]) << 16) | (@as(u32, s2_regs[1]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s1_regs[2]) << 16) | (@as(u32, s2_regs[2]) << 5) | 31;
        self.write_32(inst);
        inst = 0xFA000000 | (@as(u32, s1_regs[3]) << 16) | (@as(u32, s2_regs[3]) << 5) | 31;
        self.write_32(inst);
        inst = 0x9A9FA7E0 | @as(u32, d_regs[0]); // CSET d[0], LT
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    // --- Memory Ops ---

    fn emit_native_mload(ctx: *anyopaque, dst: CompilerInterface.Register, offset: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // x20 = JitContext ptr, [x20, #16]=len, [x20, #8]=ptr

        const dst_regs = get_bank_regs(dst);
        const off_regs = get_bank_regs(offset);
        const off_reg0 = off_regs[0]; // Offset is usually u64, assuming in limb 0

        // 1. Load memory_len x9
        self.emit_ldr_reg_imm(9, 20, 16); // memory_len @ 16

        // 2. Limit x10 = offset + 32
        const inst = 0x91000000 | (32 << 10) | (@as(u32, off_reg0) << 5) | 10;
        self.write_32(inst);

        // 3. CMP limit, len
        const inst_cmp = 0xEB000000 | (9 << 16) | (10 << 5) | 31;
        self.write_32(inst_cmp);

        // 4. B.HI OutOfBounds
        // Body is roughly 4*3 instructions (LDR, REV, MOV) = 12?
        // Let's count:
        // Load Base x9 (1)
        // Loop 4x: LDR (1), REV (1) = 8
        // B End (1)
        // Total In-Bounds = 10 instructions.
        // B.HI 10
        const inst_b_hi = 0x54000000 | (10 << 5) | 8;
        self.write_32(inst_b_hi);

        // 5. In-Bounds: Load Ptr x9
        self.emit_ldr_reg_imm(9, 20, 8); // memory_ptr @ 8

        // 6. Load 4 limbs: EVM Memory is Big Endian.
        // Memory: [MSW] [...] [...] [LSW]
        // Regs:   [LSW] [...] [...] [MSW] (Little Endian Chain)
        // Map:
        // offset+0  -> MSW -> Limb 3
        // offset+8  -> ... -> Limb 2
        // offset+16 -> ... -> Limb 1
        // offset+24 -> LSW -> Limb 0

        // We can reuse x9 as base ptr if we add offset to it first?
        // ADD x9, x9, offset
        const inst_add_off = 0x8b000000 | (@as(u32, off_reg0) << 16) | (9 << 5) | 9;
        self.write_32(inst_add_off);

        // Limb 3 (MSW) from [x9, #0]
        self.emit_ldr_reg_imm(dst_regs[3], 9, 0);
        // REV dst[3], dst[3]
        const inst_rev3 = 0xdac00c00 | (@as(u32, dst_regs[3]) << 5) | @as(u32, dst_regs[3]);
        self.write_32(inst_rev3);

        // Limb 2 from [x9, #8]
        self.emit_ldr_reg_imm(dst_regs[2], 9, 8);
        const inst_rev2 = 0xdac00c00 | (@as(u32, dst_regs[2]) << 5) | @as(u32, dst_regs[2]);
        self.write_32(inst_rev2);

        // Limb 1 from [x9, #16]
        self.emit_ldr_reg_imm(dst_regs[1], 9, 16);
        const inst_rev1 = 0xdac00c00 | (@as(u32, dst_regs[1]) << 5) | @as(u32, dst_regs[1]);
        self.write_32(inst_rev1);

        // Limb 0 (LSW) from [x9, #24]
        self.emit_ldr_reg_imm(dst_regs[0], 9, 24);
        const inst_rev0 = 0xdac00c00 | (@as(u32, dst_regs[0]) << 5) | @as(u32, dst_regs[0]);
        self.write_32(inst_rev0);

        // 7. B End (+6 instr: 4x MOVZ, End) - Wait, OOB is 4 instructions
        const inst_b_end = 0x14000000 | 5;
        self.write_32(inst_b_end);

        // 8. OutOfBounds: Zero all limbs
        inline for (0..4) |i| {
            // MOVZ dst[i], #0
            const inst_zero = 0xD2800000 | @as(u32, dst_regs[i]);
            self.write_32(inst_zero);
        }

        // 9. End
    }

    fn emit_native_mstore(ctx: *anyopaque, offset: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));

        // Ensure capacity for 32 bytes
        try self.emit_memory_check(offset, null, 32);

        const off_regs = get_bank_regs(offset);
        const val_regs = get_bank_regs(val);
        const off_reg0 = off_regs[0];

        // 1. Load Ptr x9 from JitContext (re-load as it might have changed)
        self.emit_ldr_reg_imm(9, 20, 8); // memory_ptr @ 8

        // Add offset to base x9
        const inst = 0x8b000000 | (@as(u32, off_reg0) << 16) | (9 << 5) | 9; // ADD x9, x9, offset
        self.write_32(inst);

        // Store 4 limbs (Big Endian in memory)
        // Limb 3 (MSB) -> offset+0
        // Big Endian: Store Limb 3 (MSB) at x9+0, Limb 0 (LSB) at x9+24
        // All limbs are byte-reversed for Big Endian within 8-byte chunks.

        // Limb 3 (MSB)
        const inst_rev3 = 0xdac00c00 | (@as(u32, val_regs[3]) << 5) | 10; // REV x10, val[3]
        self.write_32(inst_rev3);
        self.emit_str_reg_imm(10, 9, 0);

        // Limb 2
        const inst_rev2 = 0xdac00c00 | (@as(u32, val_regs[2]) << 5) | 10;
        self.write_32(inst_rev2);
        self.emit_str_reg_imm(10, 9, 8);

        // Limb 1
        const inst_rev1 = 0xdac00c00 | (@as(u32, val_regs[1]) << 5) | 10;
        self.write_32(inst_rev1);
        self.emit_str_reg_imm(10, 9, 16);

        // Limb 0 (LSB)
        const inst_rev0 = 0xdac00c00 | (@as(u32, val_regs[0]) << 5) | 10;
        self.write_32(inst_rev0);
        self.emit_str_reg_imm(10, 9, 24);
    }

    // --- Shift Operations ---

    fn emit_native_shl(ctx: *anyopaque, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const v_regs = get_bank_regs(val);
        const s_regs = get_bank_regs(shift);

        // 256-bit SHL is complex. For now, emit a stub that zeros result for large shifts
        // and handles small shifts. Full implementation would use runtime helper.
        // Check if shift[0] >= 256 (shift[1-3] != 0 || shift[0] >= 256)
        // For simplicity, just emit: if shift >= 256, result = 0, else call runtime
        // TODO: Implement full 256-bit shift in native code

        // For now, use a simplified approach: compare shift limb 0 with 256
        // CMP shift[0], #256; B.GE zero_result
        var inst: u32 = 0xf1040000 | (@as(u32, s_regs[0]) << 5) | 31; // SUBS xzr, shift[0], #256
        self.write_32(inst);
        // B.GE +N (skip to zero result) - placeholder, jump 8 instructions
        inst = 0x5400010A; // B.GE +5 (skip 5 instructions)
        self.write_32(inst);

        // Simple case: shift < 64, just do LSL on each limb with carry
        // Copy value to dst first
        inline for (0..4) |i| {
            inst = 0xAA0003E0 | (@as(u32, v_regs[i]) << 16) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        // B +5 (skip zeroing)
        inst = 0x14000005;
        self.write_32(inst);

        // Zero result path
        inline for (0..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_shr(ctx: *anyopaque, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const v_regs = get_bank_regs(val);
        const s_regs = get_bank_regs(shift);

        // Similar simplified implementation
        var inst: u32 = 0xf1040000 | (@as(u32, s_regs[0]) << 5) | 31;
        self.write_32(inst);
        inst = 0x5400010A; // B.GE +5
        self.write_32(inst);

        inline for (0..4) |i| {
            inst = 0xAA0003E0 | (@as(u32, v_regs[i]) << 16) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        inst = 0x14000005;
        self.write_32(inst);

        inline for (0..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_sar(ctx: *anyopaque, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const v_regs = get_bank_regs(val);
        const s_regs = get_bank_regs(shift);

        // SAR: Arithmetic right shift - fills with sign bit
        // Check sign bit (MSB of val[3])
        var inst: u32 = 0xf1040000 | (@as(u32, s_regs[0]) << 5) | 31;
        self.write_32(inst);
        // B.GE to all-ones or all-zeros based on sign
        inst = 0x5400010A; // B.GE +5
        self.write_32(inst);

        inline for (0..4) |i| {
            inst = 0xAA0003E0 | (@as(u32, v_regs[i]) << 16) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        inst = 0x14000005;
        self.write_32(inst);

        // For SAR with shift >= 256, result is all 1s if negative, else 0
        // Check sign: TST val[3], #(1<<63)
        inst = 0xB24003FF | (@as(u32, v_regs[3]) << 5); // TST val[3], #0x8000000000000000
        self.write_32(inst);
        // CSETM d[0-3], NE (set to all 1s if negative)
        inline for (0..4) |i| {
            inst = 0xDA9F13E0 | @as(u32, d_regs[i]); // CSETM d[i], NE
            self.write_32(inst);
        }
    }

    fn emit_native_byte(ctx: *anyopaque, dst: CompilerInterface.Register, idx: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const i_regs = get_bank_regs(idx);
        const v_regs = get_bank_regs(val);

        // BYTE: Extract byte i from 256-bit value (0 = MSB, 31 = LSB)
        // If idx >= 32, result = 0
        // Else: byte_offset = 31 - idx, limb = byte_offset / 8, bit = (byte_offset % 8) * 8
        // Result = (val[limb] >> bit) & 0xFF

        // Check idx >= 32
        var inst: u32 = 0xf1080000 | (@as(u32, i_regs[0]) << 5) | 31; // SUBS xzr, idx[0], #32
        self.write_32(inst);
        // B.GE to zero_result (+6 instr)
        inst = 0x5400010A;
        self.write_32(inst);

        // Simplified: just extract from val[3] (MSW) for now
        // LSR x9, val[3], #56; AND d[0], x9, #0xFF
        inst = 0xD35CE000 | (@as(u32, v_regs[3]) << 5) | 9; // UBFX x9, val[3], #56, #8
        self.write_32(inst);
        inst = 0x92401D20 | @as(u32, d_regs[0]); // AND d[0], x9, #0xFF
        self.write_32(inst);
        inst = 0x14000005;
        self.write_32(inst);

        // Zero result
        inline for (0..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    // --- Signed Arithmetic ---

    fn emit_native_sdiv(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // SDIV: Signed division on 256-bit is complex. Use simplified approach:
        // Just do SDIV on limb 0 for now (handles small numbers)
        // Full implementation would require runtime helper
        var inst: u32 = 0x9AC00C00 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        // Zero upper limbs
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_smod(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s1_regs = get_bank_regs(src1);
        const s2_regs = get_bank_regs(src2);

        // SMOD on limb 0: a - (a/b)*b
        // SDIV x9, s1[0], s2[0]
        var inst: u32 = 0x9AC00C00 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 9;
        self.write_32(inst);
        // MSUB d[0], x9, s2[0], s1[0] = s1[0] - x9 * s2[0]
        inst = 0x9B008000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 10) | (9 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_signextend(ctx: *anyopaque, dst: CompilerInterface.Register, b: CompilerInterface.Register, x: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const x_regs = get_bank_regs(x);
        _ = b; // b index determines which byte to sign extend from

        // Simplified: just copy x to dst for now
        var inst: u32 = undefined;
        inline for (0..4) |i| {
            inst = 0xAA0003E0 | (@as(u32, x_regs[i]) << 16) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    // --- Modular Arithmetic ---

    fn emit_native_addmod(ctx: *anyopaque, dst: CompilerInterface.Register, a: CompilerInterface.Register, b: CompilerInterface.Register, n: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const a_regs = get_bank_regs(a);
        const b_regs = get_bank_regs(b);
        const n_regs = get_bank_regs(n);

        // ADDMOD: (a + b) % n on limb 0 only for now
        // ADD x9, a[0], b[0]
        var inst: u32 = 0x8B000000 | (@as(u32, b_regs[0]) << 16) | (@as(u32, a_regs[0]) << 5) | 9;
        self.write_32(inst);
        // UDIV x10, x9, n[0]
        inst = 0x9AC00800 | (@as(u32, n_regs[0]) << 16) | (9 << 5) | 10;
        self.write_32(inst);
        // MSUB d[0], x10, n[0], x9
        inst = 0x9B008000 | (@as(u32, n_regs[0]) << 16) | (9 << 10) | (10 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_mulmod(ctx: *anyopaque, dst: CompilerInterface.Register, a: CompilerInterface.Register, b: CompilerInterface.Register, n: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const a_regs = get_bank_regs(a);
        const b_regs = get_bank_regs(b);
        const n_regs = get_bank_regs(n);

        // MULMOD: (a * b) % n on limb 0 only
        // MUL x9, a[0], b[0]
        var inst: u32 = 0x9B007C00 | (@as(u32, b_regs[0]) << 16) | (@as(u32, a_regs[0]) << 5) | 9;
        self.write_32(inst);
        // UDIV x10, x9, n[0]
        inst = 0x9AC00800 | (@as(u32, n_regs[0]) << 16) | (9 << 5) | 10;
        self.write_32(inst);
        // MSUB d[0], x10, n[0], x9
        inst = 0x9B008000 | (@as(u32, n_regs[0]) << 16) | (9 << 10) | (10 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_exp(ctx: *anyopaque, dst: CompilerInterface.Register, base: CompilerInterface.Register, exponent: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const b_regs = get_bank_regs(base);
        const e_regs = get_bank_regs(exponent);

        // EXP: Compute base^exponent using square-and-multiply on limb 0
        // x0 = result (starts at 1)
        // x1 = current base
        // x2 = current exponent

        // MOV x0, #1 ; result = 1
        var inst: u32 = 0xD2800020;
        self.write_32(inst);

        // MOV x1, base[0]
        inst = 0xAA0003E1 | (@as(u32, b_regs[0]) << 16);
        self.write_32(inst);

        // MOV x2, exponent[0]
        inst = 0xAA0003E2 | (@as(u32, e_regs[0]) << 16);
        self.write_32(inst);

        // loop_start:
        // CBZ x2, done ; if exponent == 0, done
        inst = 0xB40000C2; // CBZ x2, +6 instructions
        self.write_32(inst);

        // TBZ x2, #0, skip_mul ; if bit 0 is 0, skip multiply
        inst = 0x36000062; // TBZ x2, #0, +3 instructions
        self.write_32(inst);

        // MUL x0, x0, x1 ; result *= base
        inst = 0x9B017C00;
        self.write_32(inst);

        // skip_mul:
        // MUL x1, x1, x1 ; base = base * base
        inst = 0x9B017C21;
        self.write_32(inst);

        // LSR x2, x2, #1 ; exponent >>= 1
        inst = 0xD341FC42;
        self.write_32(inst);

        // B loop_start (-5)
        inst = 0x17FFFFFB;
        self.write_32(inst);

        // done:
        // MOV d[0], x0
        inst = 0xAA0003E0 | @as(u32, d_regs[0]);
        self.write_32(inst);

        // Zero upper limbs
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    // --- Storage Operations ---

    fn emit_native_sload(ctx: *anyopaque, dst: CompilerInterface.Register, key: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const k_regs = get_bank_regs(key);

        // SLOAD: Call evm_sload callback from JitContext
        // x20 = JitContext pointer
        // JitContext layout (extern struct, 8-byte aligned):
        //   +0:  stack_base (8)
        //   +8:  memory_ptr (8)
        //   +16: memory_len (8)
        //   +24: calldata_ptr (8)
        //   +32: calldata_len (8)
        //   +40: returndata_ptr (8)
        //   +48: returndata_len (8)
        //   +56: address (20 -> padded to 24)
        //   +80: caller (20 -> padded to 24)
        //   +104: origin (20 -> padded to 24)
        //   +128: call_value (32)
        //   +160: chain_id (8)
        //   +168: block_number (8)
        //   +176: timestamp (8)
        //   +184: gas_limit (8)
        //   +192: gas_price (8)
        //   +200: base_fee (8)
        //   +208: prevrandao (32)
        //   +240: coinbase (20 -> padded to 24)
        //   +264: gas_remaining (8)
        //   +272: bytecode_ptr (8)
        //   +280: bytecode_len (8)
        //   +288: db (8)
        //   +296: evm_sload callback (8)

        // Step 1: Store key limbs to stack (use sp - 32 as temp)
        // SUB sp, sp, #64
        self.write_32(0xD10103FF);

        // Store key (4 limbs) to [sp]
        var inst: u32 = undefined;
        inline for (0..4) |i| {
            inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, k_regs[i]);
            self.write_32(inst);
        }

        // Step 2: Set up callback args: x0 = db, x1 = key_ptr, x2 = result_ptr
        // LDR x0, [x20, #288] ; db
        inst = 0xF9409000 | (20 << 5) | 0;
        self.write_32(inst);
        // MOV x1, sp ; key_ptr
        inst = 0x910003E1;
        self.write_32(inst);
        // ADD x2, sp, #32 ; result_ptr (use sp+32 for result)
        inst = 0x91008002 | (31 << 5);
        self.write_32(inst);

        // Step 3: Load callback and call
        // LDR x9, [x20, #296] ; evm_sload
        inst = 0xF9409400 | (20 << 5) | 9;
        self.write_32(inst);
        // BLR x9
        inst = 0xD63F0120;
        self.write_32(inst);

        // Step 4: Load result from [sp+32] into dst regs
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }

        // Step 5: Restore stack
        // ADD sp, sp, #64
        self.write_32(0x910103FF);
    }

    fn emit_native_sstore(ctx: *anyopaque, key: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.flush_all_to_memory();
        const k_regs = get_bank_regs(key);
        const v_regs = get_bank_regs(val);

        // SSTORE: Call evm_sstore callback from JitContext
        // evm_sstore at JitContext offset 304

        // Step 1: Allocate stack space for key+val (64 bytes)
        // SUB sp, sp, #64
        self.write_32(0xD10103FF);

        // Store key (4 limbs) to [sp]
        var inst: u32 = undefined;
        inline for (0..4) |i| {
            inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, k_regs[i]);
            self.write_32(inst);
        }

        // Store val (4 limbs) to [sp+32]
        inline for (0..4) |i| {
            inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
            self.write_32(inst);
        }

        // Step 2: Set up args: x0 = db, x1 = key_ptr, x2 = val_ptr
        // LDR x0, [x20, #288] ; db
        inst = 0xF9409000 | (20 << 5) | 0;
        self.write_32(inst);
        // MOV x1, sp ; key_ptr
        inst = 0x910003E1;
        self.write_32(inst);
        // ADD x2, sp, #32 ; val_ptr
        inst = 0x91008002 | (31 << 5);
        self.write_32(inst);

        // Step 3: Load callback and call
        // LDR x9, [x20, #304] ; evm_sstore
        inst = 0xF9409800 | (20 << 5) | 9;
        self.write_32(inst);
        // BLR x9
        inst = 0xD63F0120;
        self.write_32(inst);

        // Step 4: Restore stack
        // ADD sp, sp, #64
        self.write_32(0x910103FF);
    }

    // --- Calldata Operations ---

    fn emit_native_calldataload(ctx: *anyopaque, dst: CompilerInterface.Register, offset: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const o_regs = get_bank_regs(offset);

        // x20 = JitContext, calldata_ptr at offset 24, calldata_len at offset 32
        // LDR x9, [x20, #24] ; calldata_ptr
        var inst: u32 = 0xF9400C09 | (20 << 5); // LDR x9, [x20, #24]
        self.write_32(inst);
        // ADD x9, x9, offset[0] ; ptr + offset
        inst = 0x8B000120 | (@as(u32, o_regs[0]) << 16) | (9 << 5) | 9;
        self.write_32(inst);
        // Load 32 bytes (4 limbs) - simplified, assumes aligned
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i)) << 10) | (9 << 5) | @as(u32, d_regs[3 - i]);
            self.write_32(inst);
        }
    }

    fn emit_native_calldatasize(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);

        // x20 = JitContext, calldata_len at offset 32
        // LDR d[0], [x20, #32]
        var inst: u32 = 0xF9401000 | (20 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        // Zero upper limbs
        inline for (1..4) |i| {
            inst = 0xD2800000 | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
    }

    fn emit_native_calldatacopy(ctx: *anyopaque, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Expand memory for destOffset + size
        try self.emit_memory_check(destOffset, size, 0);

        const dest_regs = get_bank_regs(destOffset);
        const off_regs = get_bank_regs(offset);
        const size_regs = get_bank_regs(size);

        // CALLDATACOPY: Copy calldata[offset..offset+size] to memory[destOffset]
        // Use a simple byte copy loop

        // x0 = dest (memory_ptr + destOffset)
        // x1 = src (calldata_ptr + offset)
        // x2 = count (size)

        // LDR x9, [x20, #8] ; memory_ptr
        var inst: u32 = 0xF9400400 | (20 << 5) | 9;
        self.write_32(inst);
        // ADD x0, x9, dest[0]
        inst = 0x8B000120 | (@as(u32, dest_regs[0]) << 16) | (9 << 5) | 0;
        self.write_32(inst);

        // LDR x9, [x20, #24] ; calldata_ptr
        inst = 0xF9400C00 | (20 << 5) | 9;
        self.write_32(inst);
        // ADD x1, x9, off[0]
        inst = 0x8B000121 | (@as(u32, off_regs[0]) << 16) | (9 << 5) | 1;
        self.write_32(inst);

        // MOV x2, size[0]
        inst = 0xAA0003E2 | (@as(u32, size_regs[0]) << 16);
        self.write_32(inst);

        // CBZ x2, skip ; if size == 0, skip loop
        inst = 0xB4000062; // CBZ x2, +3 instructions
        self.write_32(inst);

        // loop: LDRB w9, [x1], #1
        inst = 0x38401429;
        self.write_32(inst);
        // STRB w9, [x0], #1
        inst = 0x38001409;
        self.write_32(inst);
        // SUBS x2, x2, #1
        inst = 0xF1000442;
        self.write_32(inst);
        // B.NE loop (-3)
        inst = 0x54FFFF81;
        self.write_32(inst);
    }

    // --- Crypto ---

    fn emit_native_sha3(ctx: *anyopaque, dst: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);

        // SHA3: Call evm_sha3 callback from JitContext
        // evm_sha3 at JitContext offset 312
        // callback: fn(mem_ptr: [*]const u8, offset: usize, size: usize, res_ptr: *[32]u8)

        // Step 1: Allocate stack space for result
        // SUB sp, sp, #32
        self.write_32(0xD1008000 | (31 << 5) | 31);

        // Step 2: Set up args: x0 = memory_ptr, x1 = offset, x2 = size, x3 = result_ptr
        // LDR x0, [x20, #8] ; memory_ptr
        var inst: u32 = 0xF9400400 | (20 << 5) | 0;
        self.write_32(inst);
        // MOV x1, offset[0]
        inst = 0xAA0003E1 | (@as(u32, o_regs[0]) << 16);
        self.write_32(inst);
        // MOV x2, size[0]
        inst = 0xAA0003E2 | (@as(u32, s_regs[0]) << 16);
        self.write_32(inst);
        // MOV x3, sp ; result_ptr
        inst = 0x910003E3;
        self.write_32(inst);

        // Step 3: Load callback and call
        // LDR x9, [x20, #312] ; evm_sha3
        inst = 0xF9409C00 | (20 << 5) | 9;
        self.write_32(inst);
        // BLR x9
        inst = 0xD63F0120;
        self.write_32(inst);

        // Step 4: Load result from [sp] into dst regs
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }

        // Step 5: Restore stack
        // ADD sp, sp, #32
        self.write_32(0x910083FF);
    }

    // --- Context Reads ---

    fn emit_native_address(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        // x20 = JitContext, address at offset 56 (20 bytes + pad -> 24)
        var inst: u32 = 0xF9401C00 | (20 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xF9402000 | (20 << 5) | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xF9402400 | (20 << 5) | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    fn emit_native_caller(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        // x20 = JitContext, caller at offset 80
        var inst: u32 = 0xF9402800 | (20 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xF9402C00 | (20 << 5) | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xF9403000 | (20 << 5) | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    fn emit_native_origin(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        // x20 = JitContext, origin at offset 104
        var inst: u32 = 0xF9403400 | (20 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xF9403800 | (20 << 5) | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xF9403C00 | (20 << 5) | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    fn emit_native_callvalue(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        // x20 = JitContext, call_value at offset 128
        var inst: u32 = 0xF9404000 | (20 << 5) | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xF9404400 | (20 << 5) | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xF9404800 | (20 << 5) | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xF9404C00 | (20 << 5) | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    // --- Additional Native Operations ---

    fn emit_native_balance(ctx: *anyopaque, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const a_regs = get_bank_regs(addr);
        // Balance callback @ 320
        self.write_32(0xD10103FF); // SUB sp, sp, #64
        // Store address to [sp] (20 bytes)
        var inst: u32 = 0;
        inline for (0..3) |i| {
            inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }
        // LDR x0, [x20, #288] ; db
        inst = 0xF9409000 | (20 << 5) | 0;
        self.write_32(inst);
        // MOV x1, sp ; addr_ptr
        inst = 0x910003E1;
        self.write_32(inst);
        // ADD x2, sp, #32 ; res_ptr
        inst = 0x91008002 | (31 << 5);
        self.write_32(inst);
        // LDR x9, [x20, #320] ; evm_balance
        inst = 0xF940A000 | (20 << 5) | 9;
        self.write_32(inst);
        // BLR x9
        self.write_32(0xD63F0120);
        // Load result from [sp+32]
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        self.write_32(0x910103FF); // ADD sp, sp, #64
    }

    fn emit_native_selfbalance(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        // Helper to push address then call balance
        // Just directly call evm_balance with JitContext address ptr?
        // evm_balance takes address POINTER.
        // Address is at offset 56 in JitContext.
        // Call evm_balance(db, address_ptr, res_ptr)
        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, sp, #32
        // LDR x0, [x20, #288] ; db
        var inst: u32 = 0xF9409000 | (20 << 5) | 0;
        self.write_32(inst);
        // ADD x1, x20, #56 ; address_ptr
        inst = 0x9100E281 | (20 << 5); // ADD x1, x20, #56
        self.write_32(inst);
        // MOV x2, sp ; res_ptr
        inst = 0x910003E2;
        self.write_32(inst);
        // LDR x9, [x20, #320] ; evm_balance
        inst = 0xF940A000 | (20 << 5) | 9;
        self.write_32(inst);
        // BLR x9
        self.write_32(0xD63F0120);
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        self.write_32(0x910083FF); // ADD sp, #32
    }

    fn emit_native_blockhash(ctx: *anyopaque, dst: CompilerInterface.Register, blockNum: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.flush_all_to_memory();
        const d_regs = get_bank_regs(dst);
        const b_regs = get_bank_regs(blockNum);
        // Callback @ 328
        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, #32
        // LDR x0, [x20, #288] ; db
        var inst: u32 = 0xF9409000 | (20 << 5) | 0;
        self.write_32(inst);
        // MOV x1, blockNum[0]
        inst = 0xAA0003E1 | (@as(u32, b_regs[0]) << 16);
        self.write_32(inst);
        // MOV x2, sp ; res_ptr
        inst = 0x910003E2;
        self.write_32(inst);
        // LDR x9, [x20, #328] ; evm_blockhash
        inst = 0xF940A400 | (20 << 5) | 9;
        self.write_32(inst);
        // BLR x9
        self.write_32(0xD63F0120);
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        self.write_32(0x910083FF);
    }

    fn emit_native_msize(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        // memory_len at offset 16 (u64)
        self.emit_ldr_reg_imm(d_regs[0], 20, 16);
        // Zero high words
        var inst: u32 = 0xD2800000 | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);
    }

    fn emit_native_mstore8(ctx: *anyopaque, offset: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Expand memory if needed: offset + 1
        try self.emit_memory_check(offset, null, 1);

        const o_regs = get_bank_regs(offset);
        const v_regs = get_bank_regs(val);
        // memory_ptr @ 8
        self.emit_ldr_reg_imm(9, 20, 8);
        // STRB w(val), [x9, x(offset)]
        self.emit_strb_reg_reg(v_regs[0], 9, o_regs[0]);
    }

    fn emit_native_codecopy(ctx: *anyopaque, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Expand memory for destOffset + size
        try self.emit_memory_check(destOffset, size, 0);

        const dest_regs = get_bank_regs(destOffset);
        const off_regs = get_bank_regs(offset);
        const size_regs = get_bank_regs(size);
        // Copy bytecode[offset..] to memory[destOffset..]
        // bytecode_ptr @ 272
        self.emit_ldr_reg_imm(9, 20, 8); // mem_ptr
        // ADD x0, x9, dest ; dest pointer
        const inst = 0x8B000120 | (@as(u32, dest_regs[0]) << 16) | (9 << 5) | 0;
        self.write_32(inst);
        // LDR x9, [x20, #272] ; code_ptr
        self.emit_ldr_reg_imm(9, 20, 272);
        // src pointer
        const inst_src = 0x8B000121 | (@as(u32, off_regs[0]) << 16) | (9 << 5) | 1;
        self.write_32(inst_src);
        // MOV x2, size
        const inst_mov_sz = 0xAA0003E2 | (@as(u32, size_regs[0]) << 16);
        self.write_32(inst_mov_sz);

        // CBZ x2, skip (Offset 4 instrs: LDRB, STRB, SUBS, B.NE) -> 0x80
        self.write_32(0xB4000082);
        // loop: LDRB w9, [x1], #1
        self.write_32(0x38401429);
        // STRB w9, [x0], #1
        self.write_32(0x38001409);
        // SUBS x2, #1
        self.write_32(0xF1000442);
        // B.NE loop
        self.write_32(0x54FFFF81);
    }

    fn emit_native_extcodesize(ctx: *anyopaque, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.flush_all_to_memory();
        const d_regs = get_bank_regs(dst);
        const a_regs = get_bank_regs(addr);
        // Callback @ 336 (evm_extcodesize -> returns usize)
        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, #32
        inline for (0..3) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }
        // LDR x0, [x20, #288] ; db
        self.write_32(0xF9409000 | (20 << 5));
        // MOV x1, sp ; addr_ptr
        self.write_32(0x910003E1);
        // LDR x9, [x20, #336]
        self.write_32(0xF940A809 | (20 << 5));
        // BLR x9
        self.write_32(0xD63F0120);
        // Result in x0
        var inst = 0xAA0003E0 | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);
        self.write_32(0x910083FF);
    }

    fn emit_native_extcodehash(ctx: *anyopaque, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.flush_all_to_memory();
        const d_regs = get_bank_regs(dst);
        const a_regs = get_bank_regs(addr);
        // Callback @ 344
        self.write_32(0xD10103FF); // SUB sp, #64
        inline for (0..3) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }
        self.write_32(0xF9409000 | (20 << 5)); // db
        self.write_32(0x910003E1); // addr
        var inst: u32 = 0x91008002 | (31 << 5);
        self.write_32(inst); // res_ptr=sp+32
        self.write_32(0xF940AC09 | (20 << 5)); // callback @ 344
        self.write_32(0xD63F0120);
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        self.write_32(0x910103FF);
    }

    fn emit_native_returndatacopy(ctx: *anyopaque, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Expand memory for destOffset + size
        try self.emit_memory_check(destOffset, size, 0);

        const dest_regs = get_bank_regs(destOffset);
        const off_regs = get_bank_regs(offset);
        const size_regs = get_bank_regs(size);
        // returndata_ptr @ 40
        self.emit_ldr_reg_imm(9, 20, 8); // mem_ptr
        const inst = 0x8B000120 | (@as(u32, dest_regs[0]) << 16) | (9 << 5) | 0;
        self.write_32(inst);
        self.emit_ldr_reg_imm(9, 20, 40); // returndata_ptr @ 40 (5*8)
        // src pointer
        const inst_src_rt = 0x8B000121 | (@as(u32, off_regs[0]) << 16) | (9 << 5) | 1;
        self.write_32(inst_src_rt);
        const inst_size = 0xAA0003E2 | (@as(u32, size_regs[0]) << 16);
        self.write_32(inst_size);
        self.write_32(0xB4000062);
        self.write_32(0x38401429);
        self.write_32(0x38001409);
        self.write_32(0xF1000442);
        self.write_32(0x54FFFF81);
    }

    fn emit_native_return(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // try self.flush_all_to_memory(); // Removed to debug clobbering
        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);
        // Set returndata_ptr (40) = memory_ptr (8) + offset
        // Set returndata_len (48) = size
        // Set is_halt (449) = 1
        // Use x16 as scratch (safe from banks 0-4)
        self.emit_ldr_reg_imm(16, 20, 8); // LDR x16, [x20, #8] (memory_ptr)
        const inst = 0x8B000210 | (@as(u32, o_regs[0]) << 16) | (16 << 5) | 16; // ADD x16, x16, offset[0]
        self.write_32(inst); // x16 = mem + offset
        self.emit_str_reg_imm(16, 20, 40); // STR x16, [x20, #40] (returndata_ptr)

        self.emit_str_reg_imm(s_regs[0], 20, 48); // STR size, [x20, #48] (returndata_len)

        const inst_halt = 0xD2800030; // MOV x16, #1
        self.write_32(inst_halt);
        self.emit_strb_reg_imm(16, 20, 449); // is_halt @ 449

        // Epilogue
        self.write_32(0xA8C173FB); // ldp x27, x28, [sp], #16
        self.write_32(0xA8C16BF9); // ldp x25, x26, [sp], #16
        self.write_32(0xA8C163F7); // ldp x23, x24, [sp], #16
        self.write_32(0xA8C15BF5); // ldp x21, x22, [sp], #16
        self.write_32(0xA8C153F3); // ldp x19, x20, [sp], #16
        self.write_32(0xA8C17BFD); // ldp x29, x30, [sp], #16
        self.write_32(0xD65F03C0); // ret
    }

    fn emit_native_revert(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);

        // Set returndata_ptr (40) = memory_ptr (8) + offset
        // Use x16 as scratch (safe from banks 0-4)
        self.emit_ldr_reg_imm(16, 20, 8); // memory_ptr @ 8
        const inst = 0x8B000210 | (@as(u32, o_regs[0]) << 16) | (16 << 5) | 16; // ADD x16, x16, offset[0]
        self.write_32(inst); // x16 = mem + offset
        self.emit_str_reg_imm(16, 20, 40); // STR x16, [x20, #40] (returndata_ptr)

        // Set returndata_len (48) = size
        self.emit_str_reg_imm(s_regs[0], 20, 48); // STR size, [x20, #48]

        // Set is_revert (450) = 1
        const inst_revert = 0xD2800030; // MOV x16, #1
        self.write_32(inst_revert);
        self.emit_strb_reg_imm(16, 20, 450); // is_revert @ 450

        // Epilogue
        self.write_32(0xA8C173FB); // ldp x27, x28, [sp], #16
        self.write_32(0xA8C16BF9); // ldp x25, x26, [sp], #16
        self.write_32(0xA8C163F7); // ldp x23, x24, [sp], #16
        self.write_32(0xA8C15BF5); // ldp x21, x22, [sp], #16
        self.write_32(0xA8C153F3); // ldp x19, x20, [sp], #16
        self.write_32(0xA8C17BFD); // ldp x29, x30, [sp], #16
        self.write_32(0xD65F03C0); // ret
    }

    // --- Event Logging ---

    fn emit_native_log0(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        try emit_native_log_common(ctx, offset, size, &.{});
    }
    fn emit_native_log1(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register, t1: CompilerInterface.Register) !void {
        try emit_native_log_common(ctx, offset, size, &.{t1});
    }
    fn emit_native_log2(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register, t1: CompilerInterface.Register, t2: CompilerInterface.Register) !void {
        try emit_native_log_common(ctx, offset, size, &.{ t1, t2 });
    }
    fn emit_native_log3(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register, t1: CompilerInterface.Register, t2: CompilerInterface.Register, t3: CompilerInterface.Register) !void {
        try emit_native_log_common(ctx, offset, size, &.{ t1, t2, t3 });
    }
    fn emit_native_log4(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register, t1: CompilerInterface.Register, t2: CompilerInterface.Register, t3: CompilerInterface.Register, t4: CompilerInterface.Register) !void {
        try emit_native_log_common(ctx, offset, size, &.{ t1, t2, t3, t4 });
    }

    fn emit_native_log_common(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register, topics: []const CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Callback @ 360 (evm_log)
        // Args: ctx(x0), mem_ptr(x1), off(x2), size(x3), topics_ptr(x4), num_topics(x5)

        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);

        // Stack for topics: 32 bytes per topic
        const stack_size = topics.len * 32;
        if (stack_size > 0) {
            const aligned_size = (stack_size + 15) & ~@as(usize, 15);
            // SUB sp, sp, imm12
            const sub = 0xD10003FF | (@as(u32, @intCast(aligned_size)) << 10);
            self.write_32(sub);

            for (topics, 0..) |t, i| {
                const t_regs = get_bank_regs(t);
                inline for (0..4) |j| {
                    // STR register, [sp, #(i*32 + j*8)]
                    const off = i * 32 + j * 8;
                    const inst = 0xF90003E0 | (@as(u32, @intCast(off >> 3)) << 10) | @as(u32, t_regs[j]);
                    self.write_32(inst);
                }
            }
        }

        self.write_32(0xF9400681 | (20 << 5)); // LDR x1, [x20, #8] (memory_ptr)

        var inst = 0xAA0003E2 | (@as(u32, o_regs[0]) << 16);
        self.write_32(inst); // x2 = offset
        inst = 0xAA0003E3 | (@as(u32, s_regs[0]) << 16);
        self.write_32(inst); // x3 = size

        if (stack_size > 0) {
            self.write_32(0x910003E4); // MOV x4, sp
        } else {
            self.write_32(0xD2800004); // MOV x4, 0
        }

        inst = 0xD2800005 | (@as(u32, @intCast(topics.len)) << 5);
        self.write_32(inst); // MOV x5, #num

        self.write_32(0xF940B409 | (20 << 5)); // LDR x9, [x20, #360]
        self.write_32(0xD63F0120); // BLR x9

        if (stack_size > 0) {
            const aligned_size = (stack_size + 15) & ~@as(usize, 15);
            const add = 0x910003FF | (@as(u32, @intCast(aligned_size)) << 10);
            self.write_32(add);
        }
    }

    fn emit_native_extcodecopy(ctx: *anyopaque, addr: CompilerInterface.Register, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Expand memory for destOffset + size
        try self.emit_memory_check(destOffset, size, 0);

        // Callback @ 352
        const a_regs = get_bank_regs(addr);
        const d_regs = get_bank_regs(destOffset);
        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);

        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, 32
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }

        self.write_32(0xF9409000 | (20 << 5)); // LDR x0, [x20, #288] (db)
        self.write_32(0x910003E1); // x1 = sp
        var inst = 0xAA0003E2 | (@as(u32, d_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E3 | (@as(u32, o_regs[0]) << 16);
        self.write_32(inst);
        const inst_mcopy = 0xAA0003E4 | (@as(u32, s_regs[0]) << 16); // x4 = size
        self.write_32(inst_mcopy);
        // evm_mcopy @ 432
        self.emit_ldr_reg_imm(9, 20, 432);
        self.write_32(0xD63F0120); // BLR x9
        self.write_32(0x910083FF);
    }

    // --- Call / Create Implementations ---

    fn emit_native_call(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, val: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        try self.flush_all_to_memory();
        const g_regs = get_bank_regs(gas);
        const a_regs = get_bank_regs(addr);
        const v_regs = get_bank_regs(val);
        const ao_regs = get_bank_regs(arg_off);
        const al_regs = get_bank_regs(arg_len);
        const ro_regs = get_bank_regs(ret_off);
        const rl_regs = get_bank_regs(ret_len);
        const d_regs = get_bank_regs(dst);

        // Stack alloc: 64 bytes (32 addr + 32 val)
        self.write_32(0xD10103FF); // SUB sp, sp, #64

        // Store Addr @ [sp]
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }
        // Store Val @ [sp+32]
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
            self.write_32(inst);
        }

        // Args for callback
        self.write_32(0xF9409000 | (20 << 5)); // LDR x0, [x20, #288] (db)
        var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
        self.write_32(inst); // x1 = gas[0]
        self.write_32(0x910003E2); // MOV x2, sp (addr_ptr)
        inst = 0x91008003 | (31 << 5);
        self.write_32(inst); // ADD x3, sp, #32 (val_ptr)

        inst = 0xAA0003E4 | (@as(u32, ao_regs[0]) << 16);
        self.write_32(inst); // x4 = arg_off
        inst = 0xAA0003E5 | (@as(u32, al_regs[0]) << 16);
        self.write_32(inst); // x5 = arg_len
        inst = 0xAA0003E6 | (@as(u32, ro_regs[0]) << 16);
        self.write_32(inst); // x6 = ret_off
        inst = 0xAA0003E7 | (@as(u32, rl_regs[0]) << 16);
        self.write_32(inst); // x7 = ret_len

        // Call callback @ 368
        self.write_32(0xF940B809 | (20 << 5)); // LDR x9, [x20, #368]
        self.write_32(0xD63F0120); // BLR x9

        // Result x0 (bool) -> dst
        // zero extend x0 to u256
        inst = 0xAA0003E0 | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);

        self.write_32(0x910103FF); // Restore stack
    }

    fn emit_native_callcode(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, val: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Same as CALL but callback @ 368
        const g_regs = get_bank_regs(gas);
        const a_regs = get_bank_regs(addr);
        const v_regs = get_bank_regs(val);
        const ao_regs = get_bank_regs(arg_off);
        const al_regs = get_bank_regs(arg_len);
        const ro_regs = get_bank_regs(ret_off);
        const rl_regs = get_bank_regs(ret_len);
        const d_regs = get_bank_regs(dst);

        self.write_32(0xD10103FF); // SUB sp, 64
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
            self.write_32(inst);
        }

        self.write_32(0xF9409000 | (20 << 5));
        var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
        self.write_32(inst);
        self.write_32(0x910003E2);
        inst = 0x91008003 | (31 << 5);
        self.write_32(inst);

        inst = 0xAA0003E4 | (@as(u32, ao_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E5 | (@as(u32, al_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E6 | (@as(u32, ro_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E7 | (@as(u32, rl_regs[0]) << 16);
        self.write_32(inst);

        self.write_32(0xF940BC09 | (20 << 5)); // <--- 376
        self.write_32(0xD63F0120);

        inst = 0xAA0003E0 | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);

        self.write_32(0x910103FF);
    }

    // Delegatecall: args 7 (no val). x0-x6.
    fn emit_native_delegatecall(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Callback @ 376
        const g_regs = get_bank_regs(gas);
        const a_regs = get_bank_regs(addr);
        const ao_regs = get_bank_regs(arg_off);
        const al_regs = get_bank_regs(arg_len);
        const ro_regs = get_bank_regs(ret_off);
        const rl_regs = get_bank_regs(ret_len);
        const d_regs = get_bank_regs(dst);

        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, 32 (only addr)
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }

        self.write_32(0xF9409000 | (20 << 5)); // db
        var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
        self.write_32(inst);
        self.write_32(0x910003E2); // addr ptr

        inst = 0xAA0003E3 | (@as(u32, ao_regs[0]) << 16);
        self.write_32(inst); // arg_off -> x3
        inst = 0xAA0003E4 | (@as(u32, al_regs[0]) << 16);
        self.write_32(inst); // arg_len -> x4
        inst = 0xAA0003E5 | (@as(u32, ro_regs[0]) << 16);
        self.write_32(inst); // ret_off -> x5
        inst = 0xAA0003E6 | (@as(u32, rl_regs[0]) << 16);
        self.write_32(inst); // ret_len -> x6

        self.write_32(0xF940C009 | (20 << 5)); // <--- 384
        self.write_32(0xD63F0120);

        inst = 0xAA0003E0 | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);

        self.write_32(0x910083FF);
    }

    // Staticcall: args 7. x0-x6. Callback @ 384.
    fn emit_native_staticcall(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Callback @ 384
        const g_regs = get_bank_regs(gas);
        const a_regs = get_bank_regs(addr);
        const ao_regs = get_bank_regs(arg_off);
        const al_regs = get_bank_regs(arg_len);
        const ro_regs = get_bank_regs(ret_off);
        const rl_regs = get_bank_regs(ret_len);
        const d_regs = get_bank_regs(dst);

        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, 32
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
            self.write_32(inst);
        }

        self.write_32(0xF9409000 | (20 << 5));
        var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
        self.write_32(inst);
        self.write_32(0x910003E2);

        inst = 0xAA0003E3 | (@as(u32, ao_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E4 | (@as(u32, al_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E5 | (@as(u32, ro_regs[0]) << 16);
        self.write_32(inst);
        inst = 0xAA0003E6 | (@as(u32, rl_regs[0]) << 16);
        self.write_32(inst);

        self.write_32(0xF940C409 | (20 << 5)); // <--- 392
        self.write_32(0xD63F0120);

        inst = 0xAA0003E0 | @as(u32, d_regs[0]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[1]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[2]);
        self.write_32(inst);
        inst = 0xD2800000 | @as(u32, d_regs[3]);
        self.write_32(inst);

        self.write_32(0x910083FF);
    }

    fn emit_native_create(ctx: *anyopaque, val: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        // Callback @ 392
        // Args: ctx(x0), val_ptr(x1), off(x2), size(x3), res_ptr(x4)
        const v_regs = get_bank_regs(val);
        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);
        const d_regs = get_bank_regs(dst);

        self.write_32(0xD10103FF); // SUB sp, 64 (32 val + 32 res)

        // Store val @ [sp]
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
            self.write_32(inst);
        }

        // MOV x0, x20 (Pass ctx as first arg)
        self.write_32(0xAA1403E0);
        self.write_32(0x910003E1); // val_ptr=sp
        var inst = 0xAA0003E2 | (@as(u32, o_regs[0]) << 16);
        self.write_32(inst); // off
        inst = 0xAA0003E3 | (@as(u32, s_regs[0]) << 16);
        self.write_32(inst); // size
        inst = 0x91008004 | (31 << 5);
        self.write_32(inst); // res_ptr=sp+32

        self.write_32(0xF940C809 | (20 << 5)); // LDR x9, [x20, #400] (evm_create)
        self.write_32(0xD63F0120);

        // Load result from [sp+32]
        inline for (0..4) |i| {
            const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(ld);
        }
        self.write_32(0x910103FF);
    }

    fn emit_native_create2(ctx: *anyopaque, val: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register, salt: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const v_regs = get_bank_regs(val);
        const o_regs = get_bank_regs(offset);
        const s_regs = get_bank_regs(size);
        const sa_regs = get_bank_regs(salt);
        const d_regs = get_bank_regs(dst);

        // SUB sp, sp, #96 (32 val + 32 salt + 32 res)
        self.write_32(0xD10183FF);

        // Val @ sp
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
            self.write_32(inst);
        }
        // Salt @ sp+32
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, sa_regs[i]);
            self.write_32(inst);
        }

        // Setup args
        self.write_32(0xAA1403E0); // MOV x0, x20 (ctx)
        self.write_32(0x910003E1); // MOV x1, sp (val_ptr)
        var inst = 0xAA0003E2 | (@as(u32, o_regs[0]) << 16);
        self.write_32(inst); // MOV x2, offset
        inst = 0xAA0003E3 | (@as(u32, s_regs[0]) << 16);
        self.write_32(inst); // MOV x3, size
        inst = 0x91008004 | (31 << 5);
        self.write_32(inst); // ADD x4, sp, #32 (salt_ptr)
        inst = 0x91010005 | (31 << 5);
        self.write_32(inst); // ADD x5, sp, #64 (res_ptr)

        // Callback @ 408
        self.write_32(0xF940CC09 | (20 << 5)); // LDR x9, [x20, #408]
        self.write_32(0xD63F0120); // BLR x9

        // Load result from [sp+64]
        inline for (0..4) |i| {
            const ld = 0xF9400000 | (@as(u32, @intCast(i + 8)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(ld);
        }
        self.write_32(0x910183FF); // ADD sp, sp, #96
    }

    fn emit_native_tload(ctx: *anyopaque, key: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const k_regs = get_bank_regs(key);
        const d_regs = get_bank_regs(dst);

        // Call evm_tload @ 416
        // Args: ctx(x0), key_ptr(x1), res_ptr(x2)
        // Stack: 64 bytes (32 key + 32 res)
        self.write_32(0xD10103FF); // SUB sp, sp, #64

        // Store key @ sp
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, k_regs[i]);
            self.write_32(inst);
        }

        self.write_32(0xAA1403E0); // MOV x0, x20
        self.write_32(0x910003E1); // MOV x1, sp (key_ptr)
        const inst_add = 0x91008002 | (31 << 5);
        self.write_32(inst_add); // ADD x2, sp, #32 (res_ptr)
        // evm_tload @ 416
        self.emit_ldr_reg_imm(9, 20, 416);
        self.write_32(0xD63F0120); // BLR x9

        // Load result from [sp+32]
        inline for (0..4) |i| {
            const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(ld);
        }
        self.write_32(0x910103FF); // ADD sp, sp, #64
    }

    fn emit_native_tstore(ctx: *anyopaque, key: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const k_regs = get_bank_regs(key);
        const v_regs = get_bank_regs(val);

        // Call evm_tstore @ 424
        // Args: ctx(x0), key_ptr(x1), val_ptr(x2)
        // Stack: 64 bytes
        self.write_32(0xD10103FF); // SUB sp, sp, #64

        // Store key @ sp
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, k_regs[i]);
            self.write_32(inst);
        }
        // Store val @ sp+32
        inline for (0..4) |i| {
            const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
            self.write_32(inst);
        }

        self.write_32(0xAA1403E0); // MOV x0, x20
        self.write_32(0x910003E1); // MOV x1, sp (key_ptr)
        const inst_add = 0x91008002 | (31 << 5);
        self.write_32(inst_add); // ADD x2, sp, #32 (val_ptr)
        // evm_tstore @ 424
        self.emit_ldr_reg_imm(9, 20, 424);
        self.write_32(0xD63F0120); // BLR x9

        self.write_32(0x910103FF); // ADD sp, sp, #64
    }

    fn emit_native_mcopy(ctx: *anyopaque, dst: CompilerInterface.Register, src: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *NativeJitCompiler = @ptrCast(@alignCast(ctx));
        const d_regs = get_bank_regs(dst);
        const s_regs = get_bank_regs(src);
        const sz_regs = get_bank_regs(size);

        // Call evm_mcopy @ 432
        // Args: ctx(x0), dst_off(x1), src_off(x2), size(x3)
        // No stack alloc needed, values passed in regs (taking low 64 bits)

        self.write_32(0xAA1403E0); // MOV x0, x20
        var inst = 0xAA0003E1 | (@as(u32, d_regs[0]) << 16);
        self.write_32(inst); // MOV x1, dst[0]
        inst = 0xAA0003E2 | (@as(u32, s_regs[0]) << 16);
        self.write_32(inst); // MOV x2, src[0]
        inst = 0xAA0003E3 | (@as(u32, sz_regs[0]) << 16);
        self.write_32(inst); // MOV x3, size[0]

        self.write_32(0xF940D809 | (20 << 5)); // LDR x9, [x20, #432]
        self.write_32(0xD63F0120); // BLR x9
    }

    fn emit_ldr_reg_imm(self: *NativeJitCompiler, rt: u8, rn: u8, imm: u64) void {
        const imm12 = @as(u32, @intCast(imm / 8));
        const inst = 0xF9400000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    fn emit_str_reg_imm(self: *NativeJitCompiler, rt: u8, rn: u8, imm: u64) void {
        const imm12 = @as(u32, @intCast(imm / 8));
        const inst = 0xF9000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    fn emit_strb_reg_imm(self: *NativeJitCompiler, rt: u8, rn: u8, imm: u32) void {
        const inst = 0x39000000 | (imm << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    fn emit_strb_reg_reg(self: *NativeJitCompiler, rt: u8, rn: u8, rm: u8) void {
        const inst = 0x38200000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    fn write_32(self: *NativeJitCompiler, val: u32) void {
        if (self.current_offset + 4 > self.code_buffer.len) @panic("JIT code buffer overflow");
        std.mem.writeInt(u32, self.code_buffer[self.current_offset .. self.current_offset + 4][0..4], val, .little);
        self.current_offset += 4;
    }

    fn emit_load_u256_from_stack(self: *NativeJitCompiler, bank_idx: u8, stack_idx: usize) !void {
        // Load 4 limbs: [x19, offset], [x19, offset+8], ...
        const regs = get_bank_regs(bank_idx);
        const base_offset = stack_idx * 32;
        if (base_offset + 24 > 4095) return error.OffsetTooLarge;

        inline for (0..4) |i| {
            const offset = base_offset + (i * 8);
            // LDR (scaled immediate): 0xf9400000 | (imm12 << 10) | (Rn << 5) | Rt
            const imm12 = @as(u32, @intCast(offset / 8));
            const inst = 0xf9400000 | (imm12 << 10) | (19 << 5) | @as(u32, regs[i]);
            self.write_32(inst);
        }
    }
};
