const std = @import("std");
const stencils = @import("stencils");
const posix = std.posix;

// Safe page size alignment for ARM64 macOS
const PAGE_SIZE = 16384;

const JumpRelocation = struct {
    patch_offset: usize,
    target_pc: usize,
    instruction_type: enum { B, CBNZ },
};

const HoleValue = struct {
    symbol: []const u8,
    value: u64,
};

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

pub const JitCompiler = struct {
    allocator: std.mem.Allocator,
    code_buffer: []align(PAGE_SIZE) u8,
    data_buffer: []u64, // "GOT" for patchable constants
    current_offset: usize,

    // Backpatching
    bytecode_map: std.AutoHashMapUnmanaged(usize, usize), // Bytecode PC -> JIT Offset
    jump_relocs: std.ArrayListUnmanaged(JumpRelocation),

    pub fn init(allocator: std.mem.Allocator, code_size: usize) !JitCompiler {
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

        return JitCompiler{
            .allocator = allocator,
            .code_buffer = code_slice,
            .data_buffer = data_buffer,
            .current_offset = 0,
            .bytecode_map = .{},
            .jump_relocs = .{},
        };
    }

    pub fn deinit(self: *JitCompiler) void {
        posix.munmap(self.code_buffer);
        self.allocator.free(self.data_buffer);
        self.bytecode_map.deinit(self.allocator);
        self.jump_relocs.deinit(self.allocator);
    }

    pub fn finalize(self: *JitCompiler) !void {
        try self.resolve_jumps();
        try posix.mprotect(self.code_buffer, posix.PROT.READ | posix.PROT.EXEC);

        if (@import("builtin").os.tag.isDarwin()) {
            const sys_icache_invalidate = @extern(*const fn (start: *anyopaque, len: usize) callconv(.c) void, .{ .name = "sys_icache_invalidate" });
            sys_icache_invalidate(self.code_buffer.ptr, self.code_buffer.len);
        }
    }

    pub fn mark_pc(self: *JitCompiler, pc: usize) !void {
        // std.debug.print("[JIT] Marking PC {d} at offset {d}\n", .{ pc, self.current_offset });
        try self.bytecode_map.put(self.allocator, pc, self.current_offset);
    }

    fn patch_instruction(self: *JitCompiler, patch_offset: usize, value: u64) !void {
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

    pub fn emit_stencil(self: *JitCompiler, stencil: anytype, patches: []const HoleValue) !void {
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

    pub fn resolve_jumps(self: *JitCompiler) !void {
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

    pub fn compile_prologue(self: *JitCompiler) !void {
        const prologue = [_]u8{ 0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91 };
        @memcpy(self.code_buffer[self.current_offset..][0..8], &prologue);
        self.current_offset += 8;
    }

    pub fn compile_epilogue(self: *JitCompiler) !void {
        const epilogue = [_]u8{ 0xfd, 0x7b, 0xc1, 0xa8, 0xc0, 0x03, 0x5f, 0xd6 };
        @memcpy(self.code_buffer[self.current_offset..][0..8], &epilogue);
        self.current_offset += 8;
    }

    pub fn compile_bytecode(self: *JitCompiler, bytecode: []const u8) !void {
        const opcodes = @import("opcodes/index.zig");

        // Build dispatch table at comptime
        const JitFn = *const fn (jit: *JitCompiler, pc: *usize, stack_top: *u64, bytecode: []const u8) anyerror!void;
        const jit_dispatch = comptime blk: {
            var table = [_]?JitFn{null} ** 256;
            for (opcodes.all_opcodes) |op_module| {
                const op_info = op_module.getImpl();
                if (@hasDecl(op_module, "jit_compile")) {
                    table[op_info.code] = struct {
                        fn wrapper(w_jit: *JitCompiler, w_pc: *usize, w_stack_top: *u64, w_bytecode: []const u8) anyerror!void {
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
            try self.mark_pc(pc);
            const op = bytecode[pc];

            if (jit_dispatch[op]) |compile_fn| {
                pc += 1;
                try compile_fn(self, &pc, &stack_top, bytecode);
            } else {
                // Fallback or handle special cases like JUMPDEST/PUSH if not moved yet
                pc += 1;
                switch (op) {
                    0x5b => try self.compile_jumpdest(),
                    else => return error.UnsupportedOpcode,
                }
            }
        }

        try self.compile_epilogue();
        try self.finalize();
    }

    pub fn compile_move(self: *JitCompiler, dst_idx: u64, src_idx: u64) !void {
        try self.emit_stencil(stencils.Move, &[_]HoleValue{
            .{ .symbol = "_HOLE_DST", .value = dst_idx },
            .{ .symbol = "_HOLE_SRC", .value = src_idx },
        });
    }

    pub fn compile_swap(self: *JitCompiler, idx1: u64, idx2: u64) !void {
        try self.emit_stencil(stencils.Swap, &[_]HoleValue{
            .{ .symbol = "_HOLE_DST", .value = idx1 },
            .{ .symbol = "_HOLE_SRC", .value = idx2 },
        });
    }

    pub fn addressToU256(_: *JitCompiler, addr: [20]u8) u256 {
        var res: u256 = 0;
        for (addr, 0..) |byte, i| {
            res |= @as(u256, byte) << @intCast(i * 8);
        }
        return res;
    }

    pub fn compile_push(self: *JitCompiler, dst_idx: u64, value: u256) !void {
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

    pub fn compile_jump(self: *JitCompiler, target_pc: usize) !void {
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

    pub fn compile_jumpi(self: *JitCompiler, cond_idx: u64, target_pc: usize) !void {
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

    pub fn compile_jumpdest(self: *JitCompiler) !void {
        try self.emit_stencil(stencils.Jumpdest, &[_]HoleValue{});
    }

    pub fn getFunction(self: *JitCompiler) *const anyopaque {
        return @ptrCast(self.code_buffer.ptr);
    }
};
