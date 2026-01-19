const std = @import("std");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const regs_mod = @import("registers.zig");

// TLOAD: Load from transient storage
// storage[key] -> value
pub fn emit_native_tload(vm: anytype, key: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    const k_regs = regs_mod.get_bank_regs(key);
    const d_regs = regs_mod.get_bank_regs(dst);

    // Call evm_tload @ 416
    vm.write_32(0xD10103FF); // SUB sp, sp, #64

    // Store key @ sp (BE)
    inline for (0..4) |i| {
        const rev = 0xDAC00C00 | (@as(u32, k_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        const inst = 0xF90003E9 | (@as(u32, @intCast(i)) << 10);
        vm.write_32(inst);
    }

    vm.write_32(0xAA1403E0); // MOV x0, x20
    vm.write_32(0x910003E1); // MOV x1, sp (key_ptr)
    const inst_add = 0x91008002 | (31 << 5);
    vm.write_32(inst_add); // ADD x2, sp, #32 (res_ptr)

    vm.emit_ldr_reg_imm(9, 20, 416); // evm_tload
    vm.write_32(0xD63F0120); // BLR x9

    // Load result (LE)
    inline for (0..4) |i| {
        const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(ld);
    }
    vm.write_32(0x910103FF); // ADD sp, sp, #64
}

// TSTORE: Store to transient storage
pub fn emit_native_tstore(vm: anytype, key: CompilerInterface.Register, val: CompilerInterface.Register) !void {
    const k_regs = regs_mod.get_bank_regs(key);
    const v_regs = regs_mod.get_bank_regs(val);

    // Call evm_tstore @ 424
    vm.write_32(0xD10103FF); // SUB sp, sp, #64

    // Store key @ sp (BE)
    inline for (0..4) |i| {
        const rev = 0xDAC00C00 | (@as(u32, k_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        const inst = 0xF90003E9 | (@as(u32, @intCast(i)) << 10);
        vm.write_32(inst);
    }

    // Store val @ sp+32 (BE)
    inline for (0..4) |i| {
        const rev = 0xDAC00C00 | (@as(u32, v_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        const inst = 0xF90003E9 | (@as(u32, @intCast(i + 4)) << 10);
        vm.write_32(inst);
    }

    vm.write_32(0xAA1403E0); // MOV x0, x20
    vm.write_32(0x910003E1); // MOV x1, sp
    vm.write_32(0x91008002 | (31 << 5)); // ADD x2, sp, #32

    vm.emit_ldr_reg_imm(9, 20, 424); // evm_tstore
    vm.write_32(0xD63F0120); // BLR x9

    vm.write_32(0x910103FF);
}

// SLOAD: Load from storage
pub fn emit_native_sload(vm: anytype, key: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    const k_regs = regs_mod.get_bank_regs(key);
    const d_regs = regs_mod.get_bank_regs(dst);

    // evm_sload @ 296 (was 64)
    vm.write_32(0xD10103FF); // SUB sp, sp, #64

    // Store key @ sp (BE)
    inline for (0..4) |i| {
        const rev = 0xDAC00C00 | (@as(u32, k_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        const inst = 0xF90003E9 | (@as(u32, @intCast(i)) << 10);
        vm.write_32(inst);
    }

    vm.write_32(0xAA1403E0); // MOV x0, x20
    vm.write_32(0x910003E1); // MOV x1, sp
    vm.write_32(0x91008002 | (31 << 5)); // ADD x2, sp, #32

    vm.emit_ldr_reg_imm(9, 20, 296); // evm_sload
    vm.write_32(0xD63F0120); // BLR x9

    // Load result (LE)
    inline for (0..4) |i| {
        const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(ld);
    }
    vm.write_32(0x910103FF);
}

// SSTORE: Store to storage
pub fn emit_native_sstore(vm: anytype, key: CompilerInterface.Register, val: CompilerInterface.Register) !void {
    const k_regs = regs_mod.get_bank_regs(key);
    const v_regs = regs_mod.get_bank_regs(val);

    // evm_sstore @ 304 (was 72)
    vm.write_32(0xD10103FF); // SUB sp, sp, #64

    // Store key @ sp (BE)
    inline for (0..4) |i| {
        const rev = 0xDAC00C00 | (@as(u32, k_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        const inst = 0xF90003E9 | (@as(u32, @intCast(i)) << 10);
        vm.write_32(inst);
    }

    // Store val @ sp+32 (BE)
    inline for (0..4) |i| {
        const rev = 0xDAC00C00 | (@as(u32, v_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        const inst = 0xF90003E9 | (@as(u32, @intCast(i + 4)) << 10);
        vm.write_32(inst);
    }

    vm.write_32(0xAA1403E0); // MOV x0, x20
    vm.write_32(0x910003E1); // MOV x1, sp
    vm.write_32(0x91008002 | (31 << 5)); // ADD x2, sp, #32

    vm.emit_ldr_reg_imm(9, 20, 304); // evm_sstore
    vm.write_32(0xD63F0120); // BLR x9

    vm.write_32(0x910103FF);
}
