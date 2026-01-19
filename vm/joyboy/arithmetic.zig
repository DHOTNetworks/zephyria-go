const std = @import("std");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const regs_mod = @import("registers.zig");

pub fn emit_native_add(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    // Chain: ADDS, ADCS, ADCS, ADC
    // 1. ADDS d0, s1_0, s2_0 (Sets Flags)
    var inst = 0xAB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);

    // 2. ADCS d1, s1_1, s2_1 (Uses Flags, Sets Flags)
    inst = 0xBA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);

    // 3. ADCS d2, s1_2, s2_2
    inst = 0xBA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);

    // 4. ADC d3, s1_3, s2_3 (Uses Flags)
    inst = 0x9A000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_mul(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    // For now, only perform 64-bit LSD multiplication
    // mul d0, s1_0, s2_0
    const inst = 0x9b007c00 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);

    // Zero other limbs
    inline for (1..4) |i| {
        const zero_inst = 0xaa1f03e0 | @as(u32, d_regs[i]);
        vm.write_32(zero_inst);
    }
}

pub fn emit_native_sub(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    // Chain: SUBS, SBCS, SBCS, SBC
    // 1. SUBS d0, s1_0, s2_0 (Sets Flags)
    var inst = 0xEB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);

    // 2. SBCS d1, s1_1, s2_1 (Uses Flags, Sets Flags)
    inst = 0xFA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);

    // 3. SBCS d2, s1_2, s2_2
    inst = 0xFA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);

    // 4. SBC d3, s1_3, s2_3 (Uses Flags)
    inst = 0xDA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_div(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    _ = vm;
    _ = dst;
    _ = src1;
    _ = src2;
    return error.UnsupportedByNative;
}

pub fn emit_native_rem(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    _ = vm;
    _ = dst;
    _ = src1;
    _ = src2;
    return error.UnsupportedByNative;
}

pub fn emit_native_and(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    inline for (0..4) |i| {
        const inst = 0x8A000000 | (@as(u32, s2_regs[i]) << 16) | (@as(u32, s1_regs[i]) << 5) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_or(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    inline for (0..4) |i| {
        const inst = 0xAA000000 | (@as(u32, s2_regs[i]) << 16) | (@as(u32, s1_regs[i]) << 5) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_xor(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    inline for (0..4) |i| {
        const inst = 0xCA000000 | (@as(u32, s2_regs[i]) << 16) | (@as(u32, s1_regs[i]) << 5) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_not(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);

    inline for (0..4) |i| {
        const inst = 0xAA200000 | (@as(u32, s1_regs[i]) << 16) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_lt(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0xEB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x9A9F27E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_gt(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0xEB000000 | (@as(u32, s1_regs[0]) << 16) | (@as(u32, s2_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s1_regs[1]) << 16) | (@as(u32, s2_regs[1]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s1_regs[2]) << 16) | (@as(u32, s2_regs[2]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s1_regs[3]) << 16) | (@as(u32, s2_regs[3]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x9A9F27E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_eq(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0xCA000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 9;
    vm.write_32(inst);
    inst = 0xCA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | 10;
    vm.write_32(inst);
    inst = 0xAA000000 | (10 << 16) | (9 << 5) | 9;
    vm.write_32(inst);
    inst = 0xCA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | 10;
    vm.write_32(inst);
    inst = 0xAA000000 | (10 << 16) | (9 << 5) | 9;
    vm.write_32(inst);
    inst = 0xCA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | 10;
    vm.write_32(inst);
    inst = 0xAA000000 | (10 << 16) | (9 << 5) | 9;
    vm.write_32(inst);
    inst = 0xF100001F | (9 << 5);
    vm.write_32(inst);
    inst = 0x9A9F17E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_iszero(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);

    var inst: u32 = 0xAA000000 | (@as(u32, s1_regs[1]) << 16) | (@as(u32, s1_regs[0]) << 5) | 9;
    vm.write_32(inst);
    inst = 0xAA000000 | (@as(u32, s1_regs[2]) << 16) | (9 << 5) | 9;
    vm.write_32(inst);
    inst = 0xAA000000 | (@as(u32, s1_regs[3]) << 16) | (9 << 5) | 9;
    vm.write_32(inst);
    inst = 0xF100001F | (9 << 5);
    vm.write_32(inst);
    inst = 0x9A9F17E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_slt(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0xEB000000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s2_regs[1]) << 16) | (@as(u32, s1_regs[1]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s2_regs[2]) << 16) | (@as(u32, s1_regs[2]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s2_regs[3]) << 16) | (@as(u32, s1_regs[3]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x9A9FA7E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_sgt(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0xEB000000 | (@as(u32, s1_regs[0]) << 16) | (@as(u32, s2_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s1_regs[1]) << 16) | (@as(u32, s2_regs[1]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s1_regs[2]) << 16) | (@as(u32, s2_regs[2]) << 5) | 31;
    vm.write_32(inst);
    inst = 0xFA000000 | (@as(u32, s1_regs[3]) << 16) | (@as(u32, s2_regs[3]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x9A9FA7E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_shl(vm: anytype, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const v_regs = regs_mod.get_bank_regs(val);
    const s_regs = regs_mod.get_bank_regs(shift);

    var inst: u32 = 0xf1040000 | (@as(u32, s_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x5400010A;
    vm.write_32(inst);

    inline for (0..4) |i| {
        inst = 0xAA0003E0 | (@as(u32, v_regs[i]) << 16) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
    inst = 0x14000005;
    vm.write_32(inst);

    inline for (0..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_shr(vm: anytype, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const v_regs = regs_mod.get_bank_regs(val);
    const s_regs = regs_mod.get_bank_regs(shift);

    var inst: u32 = 0xf1040000 | (@as(u32, s_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x5400010A;
    vm.write_32(inst);

    inline for (0..4) |i| {
        inst = 0xAA0003E0 | (@as(u32, v_regs[i]) << 16) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
    inst = 0x14000005;
    vm.write_32(inst);

    inline for (0..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_sar(vm: anytype, dst: CompilerInterface.Register, val: CompilerInterface.Register, shift: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const v_regs = regs_mod.get_bank_regs(val);
    const s_regs = regs_mod.get_bank_regs(shift);

    var inst: u32 = 0xf1040000 | (@as(u32, s_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x5400010A;
    vm.write_32(inst);

    inline for (0..4) |i| {
        inst = 0xAA0003E0 | (@as(u32, v_regs[i]) << 16) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
    inst = 0x14000005;
    vm.write_32(inst);

    inst = 0xB24003FF | (@as(u32, v_regs[3]) << 5);
    vm.write_32(inst);
    inline for (0..4) |i| {
        inst = 0xDA9F13E0 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_byte(vm: anytype, dst: CompilerInterface.Register, idx: CompilerInterface.Register, val: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const i_regs = regs_mod.get_bank_regs(idx);
    const v_regs = regs_mod.get_bank_regs(val);

    var inst: u32 = 0xf1080000 | (@as(u32, i_regs[0]) << 5) | 31;
    vm.write_32(inst);
    inst = 0x5400010A;
    vm.write_32(inst);

    inst = 0xD35CE000 | (@as(u32, v_regs[3]) << 5) | 9;
    vm.write_32(inst);
    inst = 0x92401D20 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0x14000005;
    vm.write_32(inst);

    inline for (0..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_sdiv(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0x9AC00C00 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_smod(vm: anytype, dst: CompilerInterface.Register, src1: CompilerInterface.Register, src2: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s1_regs = regs_mod.get_bank_regs(src1);
    const s2_regs = regs_mod.get_bank_regs(src2);

    var inst: u32 = 0x9AC00C00 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 5) | 9;
    vm.write_32(inst);
    inst = 0x9B008000 | (@as(u32, s2_regs[0]) << 16) | (@as(u32, s1_regs[0]) << 10) | (9 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_signextend(vm: anytype, dst: CompilerInterface.Register, b: CompilerInterface.Register, x: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const x_regs = regs_mod.get_bank_regs(x);
    _ = b;

    var inst: u32 = undefined;
    inline for (0..4) |i| {
        inst = 0xAA0003E0 | (@as(u32, x_regs[i]) << 16) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_addmod(vm: anytype, dst: CompilerInterface.Register, a: CompilerInterface.Register, b: CompilerInterface.Register, n: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const a_regs = regs_mod.get_bank_regs(a);
    const b_regs = regs_mod.get_bank_regs(b);
    const n_regs = regs_mod.get_bank_regs(n);

    var inst: u32 = 0x8B000000 | (@as(u32, b_regs[0]) << 16) | (@as(u32, a_regs[0]) << 5) | 9;
    vm.write_32(inst);
    inst = 0x9AC00800 | (@as(u32, n_regs[0]) << 16) | (9 << 5) | 10;
    vm.write_32(inst);
    inst = 0x9B008000 | (@as(u32, n_regs[0]) << 16) | (9 << 10) | (10 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_mulmod(vm: anytype, dst: CompilerInterface.Register, a: CompilerInterface.Register, b: CompilerInterface.Register, n: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const a_regs = regs_mod.get_bank_regs(a);
    const b_regs = regs_mod.get_bank_regs(b);
    const n_regs = regs_mod.get_bank_regs(n);

    var inst: u32 = 0x9B007C00 | (@as(u32, b_regs[0]) << 16) | (@as(u32, a_regs[0]) << 5) | 9;
    vm.write_32(inst);
    inst = 0x9AC00800 | (@as(u32, n_regs[0]) << 16) | (9 << 5) | 10;
    vm.write_32(inst);
    inst = 0x9B008000 | (@as(u32, n_regs[0]) << 16) | (9 << 10) | (10 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inline for (1..4) |i| {
        inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_exp(vm: anytype, dst: CompilerInterface.Register, base: CompilerInterface.Register, exponent: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const b_regs = regs_mod.get_bank_regs(base);
    const e_regs = regs_mod.get_bank_regs(exponent);

    var inst: u32 = 0xD2800020;
    vm.write_32(inst);
    inst = 0xAA0003E1 | (@as(u32, b_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E2 | (@as(u32, e_regs[0]) << 16);
    vm.write_32(inst);
    // ... stub ...
    _ = d_regs;
}
