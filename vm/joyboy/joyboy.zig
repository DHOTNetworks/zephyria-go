// File: src/vm/native_compiler.zig
const std = @import("std");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const regs_mod = @import("registers.zig");
const mem_mod = @import("memory.zig");
const stack_mod = @import("stack.zig");
const storage_mod = @import("storage.zig");
const arithmetic_mod = @import("arithmetic.zig");
const control_mod = @import("control.zig");
const context_mod = @import("context.zig");
const Emitter = @import("emitter.zig").Emitter;
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

/// JoyboyVM implements a register-allocated JIT for EVM (formerly JoyboyVM).
/// It maps the top of the EVM stack to difference machine registers.
pub const JoyboyVM = struct {
    allocator: std.mem.Allocator,
    emitter: Emitter,

    current_bytecode_pc: usize = 0, // Track current PC for JUMPDEST

    // Register Management (Banks of 4 registers for u256)
    register_banks: [regs_mod.NUM_BANKS]regs_mod.RegisterBankState,
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

    pub fn init(allocator: std.mem.Allocator, code_size: usize) !JoyboyVM {
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

        var self = JoyboyVM{
            .allocator = allocator,
            .emitter = Emitter.init(code_slice),

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

    pub fn finalize(self: *JoyboyVM) !void {
        try self.resolve_jumps();
        try posix.mprotect(self.emitter.code_buffer, posix.PROT.READ | posix.PROT.EXEC);

        // Enable Execute access (Disable Write)
        pthread_jit_write_protect_np(1);

        if (@import("builtin").os.tag.isDarwin()) {
            const sys_icache_invalidate = @extern(*const fn (start: *anyopaque, len: usize) callconv(.c) void, .{ .name = "sys_icache_invalidate" });
            sys_icache_invalidate(self.emitter.code_buffer.ptr, self.emitter.code_buffer.len);
        }
    }

    fn resolve_jumps(self: *JoyboyVM) !void {
        for (self.pending_jumps.items) |rel| {
            const target_pc = rel.target_pc;
            if (self.jump_destinations.get(target_pc)) |dest_offset| {
                const instr_off = rel.inst_offset;
                const offset_diff = @as(i64, @intCast(dest_offset)) - @as(i64, @intCast(instr_off));
                const imm19 = @divExact(offset_diff, 4);

                // Read instruction
                const old_inst = std.mem.readInt(u32, self.emitter.code_buffer[instr_off..][0..4], .little);
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
                std.mem.writeInt(u32, self.emitter.code_buffer[instr_off..][0..4], new_inst, .little);
            }
        }
    }

    pub fn reset(self: *JoyboyVM) !void {
        // Enable Write access (Disable Exec)
        pthread_jit_write_protect_np(0);

        try posix.mprotect(self.emitter.code_buffer, posix.PROT.READ | posix.PROT.WRITE);
        self.emitter.current_offset = 0;

        self.virtual_stack.clearRetainingCapacity();
        for (&self.register_banks) |*r| {
            r.* = .{ .is_free = true, .stack_idx = null, .locked = false };
        }
        self.jump_destinations.clearRetainingCapacity();
        self.pending_jumps.clearRetainingCapacity();
    }

    pub fn compile_bytecode(self: *JoyboyVM, bytecode: []const u8) !usize {
        const opcodes = @import("../opcodes/index.zig");
        var pc: usize = 0;
        var stack_top: u64 = 0;
        try self.compile_prologue();

        compiler_loop: while (pc < bytecode.len) {
            self.current_bytecode_pc = pc; // Update context
            const op = bytecode[pc];
            // Compile opcode at current PC
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

    pub fn compile_prologue(self: *JoyboyVM) !void {
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

    pub fn flush_all_to_memory(self: *JoyboyVM) !void {
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
                    const regs = regs_mod.get_bank_regs(bank);
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

    pub fn compile_epilogue(self: *JoyboyVM) !void {
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

    pub fn getFunction(self: *JoyboyVM) *const anyopaque {
        return @ptrCast(self.emitter.code_buffer.ptr);
    }

    pub fn init_registers(self: *JoyboyVM) void {
        for (&self.register_banks) |*r| {
            r.* = .{ .is_free = true, .stack_idx = null, .locked = false };
        }
    }

    pub fn deinit(self: *JoyboyVM) void {
        posix.munmap(self.emitter.code_buffer);
        self.virtual_stack.deinit(self.allocator);
        self.jump_destinations.deinit();
        self.pending_jumps.deinit(self.allocator);
    }

    pub fn compiler(self: *JoyboyVM) CompilerInterface {
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
                .compile_pop = compile_pop,
                .compile_swap = compile_swap,
                .compile_move = compile_move,
            },
        };
    }

    fn compile_push(ctx: *anyopaque, stack_idx: u64, value: u256) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.compile_push(self, stack_idx, value);
    }
    fn compile_jump(ctx: *anyopaque, target_pc: usize) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        // Flush before jump to ensure target sees consistent memory state
        try self.flush_all_to_memory();
        // Emit placeholder B 0
        const inst = 0x14000000;
        try self.pending_jumps.append(self.allocator, .{ .inst_offset = self.emitter.current_offset, .target_pc = target_pc, .type = .Uncond });
        self.write_32(inst);
    }

    fn compile_jumpi(ctx: *anyopaque, condition_stack_idx: u64, target_pc: usize) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        // Materialize condition register
        const cond_slot_idx = @as(usize, @intCast(condition_stack_idx));
        try materialize_slot(ctx, cond_slot_idx);
        const slot = get_virtual_slot(ctx, cond_slot_idx);

        const reg = switch (slot) {
            .register => |r| r,
            else => return error.InvalidStackState,
        };

        const regs = regs_mod.get_bank_regs(reg);
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
                    const r_regs = regs_mod.get_bank_regs(bank);
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
            .inst_offset = self.emitter.current_offset,
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
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        // Flush before JUMPDEST to ensure anyone jumping HERE sees consistent state
        try self.flush_all_to_memory();
        try self.jump_destinations.put(self.current_bytecode_pc, self.emitter.current_offset);
    }

    fn compile_move(ctx: *anyopaque, dst_idx: u64, src_idx: u64) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.compile_move(self, dst_idx, src_idx);
    }

    fn compile_swap(ctx: *anyopaque, idx1: u64, idx2: u64) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.compile_swap(self, idx1, idx2);
    }

    fn compile_mload(ctx: *anyopaque, offset_idx: u64) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
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
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        const off_sidx = @as(usize, @intCast(offset_idx));
        const val_sidx = @as(usize, @intCast(val_idx));

        try materialize_slot(ctx, off_sidx);
        try materialize_slot(ctx, val_sidx);

        const off_reg = get_virtual_slot(ctx, off_sidx).register;
        const val_reg = get_virtual_slot(ctx, val_sidx).register;

        try self.emit_native_mstore(off_reg, val_reg);
        self.unlock_all_banks();
    }

    fn compile_pop(ctx: *anyopaque, stack_idx: u64) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.compile_pop(self, stack_idx);
    }

    // --- Memory Expansion Helper ---
    fn emit_memory_check(self: *JoyboyVM, offset_reg: CompilerInterface.Register, size_reg: ?CompilerInterface.Register, imm_size: u64) !void {
        try mem_mod.emit_memory_check(self, offset_reg, size_reg, imm_size);
    }

    // --- Interface Implementation ---

    // --- Interface Implementation ---

    fn get_virtual_slot(ctx: *anyopaque, stack_idx: usize) CompilerInterface.VirtualSlot {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        return stack_mod.get_virtual_slot(self, stack_idx);
    }

    fn push_virtual_constant(ctx: *anyopaque, val: u256) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.push_virtual_constant(self, val);
    }

    fn push_virtual_memory(ctx: *anyopaque) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.push_virtual_memory(self);
    }

    fn pop_virtual(ctx: *anyopaque, n: usize) void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        stack_mod.pop_virtual(self, n);
    }

    fn materialize_slot(ctx: *anyopaque, stack_idx: usize) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.materialize_slot(self, stack_idx);
    }

    fn sync_virtual_stack(ctx: *anyopaque, stack_top: u64) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try stack_mod.sync_virtual_stack(self, stack_top);
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

    fn unlock_all_banks(self: *JoyboyVM) void {
        stack_mod.unlock_all_banks(self);
    }

    // Inserting `allocate_bank` and `emit_spill_bank` here replacing original allocate_bank

    // allocate_bank and emit_spill_bank removed (logic in stack.zig)

    fn emit_stencil(_: *anyopaque, _: []const u8, _: []const CompilerInterface.HoleValue) !void {
        return; // Stencil fallback is not used in pure native mode for now
    }

    pub fn emit_load_u64(self: *JoyboyVM, reg: u8, val: u64) !void {
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
        const self = @as(*JoyboyVM, @ptrCast(@alignCast(ctx)));
        try stack_mod.push_virtual_register(self, reg);
    }

    // --- Native Emission ---

    fn emit_native_add(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_add(self, dst, src1, src2);
    }

    fn emit_native_mul(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_mul(self, dst, src1, src2);
    }

    fn emit_native_sub(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_sub(self, dst, src1, src2);
    }

    fn emit_native_div(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        return arithmetic_mod.emit_native_div(self, dst, src1, src2);
    }

    fn emit_native_rem(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        return arithmetic_mod.emit_native_rem(self, dst, src1, src2);
    }

    fn emit_native_and(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_and(self, dst, src1, src2);
    }

    fn emit_native_or(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_or(self, dst, src1, src2);
    }

    fn emit_native_xor(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_xor(self, dst, src1, src2);
    }

    fn emit_native_not(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_not(self, dst, src1);
    }

    fn emit_native_lt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_lt(self, dst, src1, src2);
    }

    fn emit_native_gt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_gt(self, dst, src1, src2);
    }

    fn emit_native_eq(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_eq(self, dst, src1, src2);
    }

    fn emit_native_iszero(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_iszero(self, dst, src1);
    }

    fn emit_native_slt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_slt(self, dst, src1, src2);
    }

    fn emit_native_sgt(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_sgt(self, dst, src1, src2);
    }

    // --- Memory Ops ---

    fn emit_native_mload(ctx: *anyopaque, dst: CompilerInterface.Register, offset: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_mload(self, dst, offset);
    }

    fn emit_native_mstore(ctx: *anyopaque, offset: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_mstore(self, offset, val);
    }

    // --- Shift Operations ---

    fn emit_native_shl(ctx: *anyopaque, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_shl(self, dst, val, shift);
    }

    fn emit_native_shr(ctx: *anyopaque, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_shr(self, dst, val, shift);
    }

    fn emit_native_sar(ctx: *anyopaque, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_sar(self, dst, val, shift);
    }

    fn emit_native_byte(ctx: *anyopaque, dst: CompilerInterface.Register, idx: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_byte(self, dst, idx, val);
    }

    // --- Signed Arithmetic ---

    fn emit_native_sdiv(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_sdiv(self, dst, src1, src2);
    }

    fn emit_native_smod(ctx: *anyopaque, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_smod(self, dst, src1, src2);
    }

    fn emit_native_signextend(ctx: *anyopaque, dst: CompilerInterface.Register, b: CompilerInterface.Register, x: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_signextend(self, dst, b, x);
    }

    // --- Modular Arithmetic ---

    fn emit_native_addmod(ctx: *anyopaque, dst: CompilerInterface.Register, a: CompilerInterface.Register, b: CompilerInterface.Register, n: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_addmod(self, dst, a, b, n);
    }

    fn emit_native_mulmod(ctx: *anyopaque, dst: CompilerInterface.Register, a: CompilerInterface.Register, b: CompilerInterface.Register, n: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_mulmod(self, dst, a, b, n);
    }

    fn emit_native_exp(ctx: *anyopaque, dst: CompilerInterface.Register, base: CompilerInterface.Register, exponent: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try arithmetic_mod.emit_native_exp(self, dst, base, exponent);
    }

    // --- Storage Operations ---

    fn emit_native_sload(ctx: *anyopaque, dst: CompilerInterface.Register, key: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try storage_mod.emit_native_sload(self, key, dst);
    }

    fn emit_native_sstore(ctx: *anyopaque, key: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try storage_mod.emit_native_sstore(self, key, val);
    }

    // --- Calldata Operations ---

    fn emit_native_calldataload(ctx: *anyopaque, dst: CompilerInterface.Register, offset: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_calldataload(self, dst, offset);
    }

    fn emit_native_calldatasize(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_calldatasize(self, dst);
    }

    fn emit_native_calldatacopy(ctx: *anyopaque, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_calldatacopy(self, destOffset, offset, size);
    }

    // --- Crypto ---

    fn emit_native_sha3(ctx: *anyopaque, dst: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        const d_regs = regs_mod.get_bank_regs(dst);
        const o_regs = regs_mod.get_bank_regs(offset);
        const s_regs = regs_mod.get_bank_regs(size);

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
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_address(self, dst);
    }

    fn emit_native_caller(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_caller(self, dst);
    }

    fn emit_native_origin(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_origin(self, dst);
    }

    fn emit_native_callvalue(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_callvalue(self, dst);
    }

    // --- Additional Native Operations ---

    fn emit_native_balance(ctx: *anyopaque, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_balance(self, dst, addr);
    }

    fn emit_native_selfbalance(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        // selfbalance implementation not in context.zig yet, maybe delegate to balance(self.address)?
        // or just copy implementation there?
        // I put selfbalance in context.zig? Let's check listing.
        // It was NOT in context.zig. I missed it.
        // But emit_native_balance is there.
        // I will leave selfbalance here for now or add to context.zig later.
        // Wait, context.zig has: address, caller, origin, callvalue, balance, blockhash...
        // No selfbalance.
        // I'll leave selfbalance here in joyboy.zig for now.
        const d_regs = regs_mod.get_bank_regs(dst);
        self.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, sp, #32
        var inst: u32 = 0xF9409000 | (20 << 5) | 0;
        self.write_32(inst);
        inst = 0x9100E281 | (20 << 5); // ADD x1, x20, #56
        self.write_32(inst);
        inst = 0x910003E2;
        self.write_32(inst);
        inst = 0xF940A000 | (20 << 5) | 9;
        self.write_32(inst);
        self.write_32(0xD63F0120);
        inline for (0..4) |i| {
            inst = 0xF9400000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
            self.write_32(inst);
        }
        self.write_32(0x910083FF); // ADD sp, #32
    }

    fn emit_native_blockhash(ctx: *anyopaque, dst: CompilerInterface.Register, blockNum: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_blockhash(self, dst, blockNum);
    }

    fn emit_native_msize(ctx: *anyopaque, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_msize(self, dst);
    }

    fn emit_native_mstore8(ctx: *anyopaque, offset: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_mstore8(self, offset, val);
    }

    fn emit_native_codecopy(ctx: *anyopaque, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_codecopy(self, destOffset, offset, size);
    }

    fn emit_native_extcodesize(ctx: *anyopaque, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_extcodesize(self, dst, addr);
    }

    fn emit_native_extcodehash(ctx: *anyopaque, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try context_mod.emit_native_extcodehash(self, dst, addr);
    }

    fn emit_native_returndatacopy(ctx: *anyopaque, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_returndatacopy(self, destOffset, offset, size);
    }

    fn emit_native_return(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_return(self, offset, size);
    }

    fn emit_native_revert(ctx: *anyopaque, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_revert(self, offset, size);
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
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_log_common(self, offset, size, topics);
    }

    fn emit_native_extcodecopy(ctx: *anyopaque, addr: CompilerInterface.Register, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_extcodecopy(self, addr, destOffset, offset, size);
    }

    // --- Call / Create Implementations ---

    fn emit_native_call(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, val: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_call(self, gas, addr, val, arg_off, arg_len, ret_off, ret_len, dst);
    }

    fn emit_native_callcode(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, val: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_callcode(self, gas, addr, val, arg_off, arg_len, ret_off, ret_len, dst);
    }

    // Delegatecall: args 7 (no val). x0-x6.
    fn emit_native_delegatecall(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_delegatecall(self, gas, addr, arg_off, arg_len, ret_off, ret_len, dst);
    }

    // Staticcall: args 7. x0-x6. Callback @ 384.
    fn emit_native_staticcall(ctx: *anyopaque, gas: CompilerInterface.Register, addr: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_staticcall(self, gas, addr, arg_off, arg_len, ret_off, ret_len, dst);
    }

    fn emit_native_create(ctx: *anyopaque, val: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_create(self, val, offset, size, dst);
    }

    fn emit_native_create2(ctx: *anyopaque, val: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register, salt: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try control_mod.emit_native_create2(self, val, offset, size, salt, dst);
    }

    fn emit_native_tload(ctx: *anyopaque, key: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try storage_mod.emit_native_tload(self, key, dst);
    }

    fn emit_native_tstore(ctx: *anyopaque, key: CompilerInterface.Register, val: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try storage_mod.emit_native_tstore(self, key, val);
    }

    fn emit_native_mcopy(ctx: *anyopaque, dst: CompilerInterface.Register, src: CompilerInterface.Register, size: CompilerInterface.Register) !void {
        const self: *JoyboyVM = @ptrCast(@alignCast(ctx));
        try mem_mod.emit_native_mcopy(self, dst, src, size);
    }

    pub fn write_32(self: *JoyboyVM, val: u32) void {
        self.emitter.write_32(val);
    }

    pub fn emit_ldr_reg_imm(self: *JoyboyVM, rt: u8, rn: u8, imm: u64) void {
        self.emitter.emit_ldr_reg_imm(rt, rn, imm);
    }

    pub fn emit_str_reg_imm(self: *JoyboyVM, rt: u8, rn: u8, imm: u64) void {
        self.emitter.emit_str_reg_imm(rt, rn, imm);
    }

    pub fn emit_strb_reg_imm(self: *JoyboyVM, rt: u8, rn: u8, imm: u32) void {
        self.emitter.emit_strb_reg_imm(rt, rn, imm);
    }

    pub fn emit_strb_reg_reg(self: *JoyboyVM, rt: u8, rn: u8, rm: u8) void {
        self.emitter.emit_strb_reg_reg(rt, rn, rm);
    }

    pub fn emit_load_u256_from_stack(self: *JoyboyVM, bank_idx: u8, stack_idx: usize) !void {
        try self.emitter.emit_load_u256_from_stack(bank_idx, stack_idx);
    }
};
