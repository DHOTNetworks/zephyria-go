const std = @import("std");
const regs_mod = @import("registers.zig");

// Helper for ARM64 code emission
pub const PAGE_SIZE = 16384;

pub const Emitter = struct {
    code_buffer: []align(PAGE_SIZE) u8,
    current_offset: usize,

    pub fn init(code_buffer: []align(PAGE_SIZE) u8) Emitter {
        return Emitter{
            .code_buffer = code_buffer,
            .current_offset = 0,
        };
    }

    pub fn write_32(self: *Emitter, val: u32) void {
        if (self.current_offset + 4 > self.code_buffer.len) @panic("JIT code buffer overflow");
        std.mem.writeInt(u32, self.code_buffer[self.current_offset .. self.current_offset + 4][0..4], val, .little);
        self.current_offset += 4;
    }

    pub fn emit_ldr_reg_imm(self: *Emitter, rt: u8, rn: u8, imm: u64) void {
        const imm12 = @as(u32, @intCast(imm / 8));
        const inst = 0xF9400000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    pub fn emit_str_reg_imm(self: *Emitter, rt: u8, rn: u8, imm: u64) void {
        const imm12 = @as(u32, @intCast(imm / 8));
        const inst = 0xF9000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    pub fn emit_strb_reg_imm(self: *Emitter, rt: u8, rn: u8, imm: u32) void {
        const inst = 0x39000000 | (imm << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    pub fn emit_strb_reg_reg(self: *Emitter, rt: u8, rn: u8, rm: u8) void {
        // STRB Wt, [Xn, Xm, LSL #0] (Extended register offset)
        // Base: 0x38200000 | (3 << 13) | (2 << 10) = 0x38206800
        const inst = 0x38206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
        self.write_32(inst);
    }

    pub fn emit_load_u256_from_stack(self: *Emitter, bank_idx: u8, stack_idx: usize) !void {
        // Load 4 limbs: [x19, offset], [x19, offset+8], ...
        const regs = regs_mod.get_bank_regs(bank_idx);
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
