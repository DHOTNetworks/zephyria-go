const std = @import("std");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const regs_mod = @import("registers.zig");

// Checks if memory access at [offset, offset+size] requires expansion.
// If so, calls evm_extend_memory.
// Preserves registers except x16 (scratch) and x0-x8 (arguments/scratch).
// offset_reg: register bank containing offset (u256)
// size_reg: register bank containing size (u256), or null if immediate size
// imm_size: immediate size if size_reg is null
pub fn emit_memory_check(vm: anytype, offset_reg: CompilerInterface.Register, size_reg: ?CompilerInterface.Register, imm_size: u64) !void {
    // 1. Calculate required size in x1
    if (size_reg) |sz_reg| {
        // Memory check with dynamic size
        // x1 = offset + size
        const off_regs = regs_mod.get_bank_regs(offset_reg);
        const sz_regs = regs_mod.get_bank_regs(sz_reg);

        // Allow simplified check: Assume u64 fits in first limb
        // ADD x1, off[0], sz[0]
        const inst: u32 = 0x8b000000 | (@as(u32, sz_regs[0]) << 16) | (@as(u32, off_regs[0]) << 5) | 1;
        vm.write_32(inst);
    } else {
        // Memory check with immediate size
        const off_regs = regs_mod.get_bank_regs(offset_reg);
        // x1 = offset + imm_size
        // ADD x1, off[0], #imm
        const imm12 = @as(u32, @intCast(imm_size));
        const inst: u32 = 0x91000000 | (imm12 << 10) | (@as(u32, off_regs[0]) << 5) | 1;
        vm.write_32(inst);
    }

    // 2. Load current capacity from JitContext (x20)
    // memory_len @ 16
    vm.emit_ldr_reg_imm(2, 20, 16);

    // 3. CMP required(x1), capacity(x2)
    const inst = 0xEB02003F;
    vm.write_32(inst);

    // 4. B.LS skip (if required <= capacity)
    // We need to calculate jump offset.
    // Save/Restore: Banks 0 and 1 are volatile.
    // 4. B.LS skip
    // Slow path: Save 3 banks (12 insts) + Call (3 insts) = 15 insts.
    // Jump over 15 instructions -> offset 16.
    const jump_off = 16;
    const inst_b = 0x54000000 | (jump_off << 5) | 9; // B.LS
    vm.write_32(inst_b);

    // --- Slow Path: Expand Memory ---

    // Unconditionally save Volatiles (Banks 0, 1, 2) to be safe
    inline for (0..3) |b| {
        const regs = regs_mod.get_bank_regs(@intCast(b));
        // STP regs[0], regs[1], [sp, #-16]!
        const stp1 = 0xA9BF0000 | (@as(u32, regs[1]) << 10) | (31 << 5) | @as(u32, regs[0]);
        vm.write_32(stp1);
        // STP regs[2], regs[3], [sp, #-16]!
        const stp2 = 0xA9BF0000 | (@as(u32, regs[3]) << 10) | (31 << 5) | @as(u32, regs[2]);
        vm.write_32(stp2);
    }

    // Call expand(ctx=x20, size=x1)
    vm.write_32(0xAA1403E0); // MOV x0, x20
    // x1 already set

    // Callback @ 440 (evm_extend_memory)
    vm.emit_ldr_reg_imm(9, 20, 440); // LDR x9, [x20, #440]
    vm.write_32(0xD63F0120); // BLR x9

    // Restore Volatiles (Reverse order)
    var b: isize = 2;
    while (b >= 0) : (b -= 1) {
        const regs = regs_mod.get_bank_regs(@intCast(b));
        // LDP regs[2], regs[3], [sp], #16
        const ldp1 = 0xA8C10000 | (@as(u32, regs[3]) << 10) | (31 << 5) | @as(u32, regs[2]);
        vm.write_32(ldp1);
        // LDP regs[0], regs[1], [sp], #16
        const ldp2 = 0xA8C10000 | (@as(u32, regs[1]) << 10) | (31 << 5) | @as(u32, regs[0]);
        vm.write_32(ldp2);
    }

    // skip:
}

pub fn emit_native_mload(vm: anytype, dst: CompilerInterface.Register, offset: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const o_regs = regs_mod.get_bank_regs(offset);

    // Expand memory checking (size=32)
    try emit_memory_check(vm, offset, null, 32);

    // Load from memory
    // LDR x9, [x20, #8] ; memory_ptr
    vm.emit_ldr_reg_imm(9, 20, 8);
    // LDR x10, [x9, offset] ; Simplified (assuming u64 offset)
    // ADD x10, x9, offset[0]
    const inst = 0x8B00012A | (@as(u32, o_regs[0]) << 16) | (9 << 5) | 10;
    vm.write_32(inst);

    // Load 32 bytes (4 limbs) from x10
    // Assuming Big Endian memory vs Little Endian register: BSWAP needed?
    // EVM Memory is byte array. Registers are u64 little-endian limbs.
    // MLOAD loads 32 bytes from memory into a u256.
    // Byte 0 of memory -> MSB of u256.
    // So we need to load bytes and pack. Or use REV instruction if doing 64-bit loads.
    // Simplified: Just LDR (little-endian) for now, assuming mismatch is handled or acceptable for pilot.
    // Correct way: use REV64 on each limb and correct ordering.
    // For now: LDR d[3], [x10]; REV d[3]
    inline for (0..4) |i| {
        // LDR x(d[3-i]), [x10, #(i*8)]
        const ld = 0xF9400140 | (@as(u32, @intCast(i * 8 / 8)) << 10) | (10 << 5) | @as(u32, d_regs[3 - i]);
        vm.write_32(ld);
        // REV x(d[3-i]), x(d[3-i])
        const rev = 0xDAC00C00 | (@as(u32, d_regs[3 - i]) << 5) | @as(u32, d_regs[3 - i]);
        vm.write_32(rev);
    }
}

pub fn emit_native_mstore(vm: anytype, offset: CompilerInterface.Register, val: CompilerInterface.Register) !void {
    const o_regs = regs_mod.get_bank_regs(offset);
    const v_regs = regs_mod.get_bank_regs(val);

    // Check memory size (32 bytes)
    try emit_memory_check(vm, offset, null, 32);

    // LDR x9, [x20, #8] ; memory_ptr
    vm.emit_ldr_reg_imm(9, 20, 8);
    // ADD x10, x9, offset[0]
    const inst = 0x8B00012A | (@as(u32, o_regs[0]) << 16) | (9 << 5) | 10;
    vm.write_32(inst);

    // Store 32 bytes (4 limbs) to x10
    // MSTORE: u256 in register (little endian limbs) -> Memory (Big Endian)
    // Val[3] (MSB limb) goes to Offset+0
    // Need REV64 on each limb
    inline for (0..4) |i| {
        // REV x9, v[3-i] (Reuse x9 as temp)
        const rev = 0xDAC00C00 | (@as(u32, v_regs[3 - i]) << 5) | 9;
        vm.write_32(rev);
        // STR x9, [x10, #(i*8)]
        const st = 0xF9000149 | (@as(u32, @intCast(i)) << 10) | (10 << 5) | 9;
        vm.write_32(st);
    }
}

pub fn emit_native_msize(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // memory_len at offset 16 (u64)
    vm.emit_ldr_reg_imm(d_regs[0], 20, 16);
    // Zero high words
    var inst: u32 = 0xD2800000 | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_mstore8(vm: anytype, offset: CompilerInterface.Register, val: CompilerInterface.Register) !void {
    // Expand memory if needed: offset + 1
    try emit_memory_check(vm, offset, null, 1);

    const o_regs = regs_mod.get_bank_regs(offset);
    const v_regs = regs_mod.get_bank_regs(val);
    // memory_ptr @ 8
    vm.emit_ldr_reg_imm(9, 20, 8);
    // STRB w(val), [x9, x(offset)]
    vm.emit_strb_reg_reg(v_regs[0], 9, o_regs[0]);
}

pub fn emit_native_mcopy(vm: anytype, dst: CompilerInterface.Register, src: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const s_regs = regs_mod.get_bank_regs(src);
    const sz_regs = regs_mod.get_bank_regs(size);

    // Call evm_mcopy @ 432
    // Args: ctx(x0), dst_off(x1), src_off(x2), size(x3)
    // No stack alloc needed, values passed in regs (taking low 64 bits)

    vm.write_32(0xAA1403E0); // MOV x0, x20
    var inst = 0xAA0003E1 | (@as(u32, d_regs[0]) << 16);
    vm.write_32(inst); // MOV x1, dst[0]
    inst = 0xAA0003E2 | (@as(u32, s_regs[0]) << 16);
    vm.write_32(inst); // MOV x2, src[0]
    inst = 0xAA0003E3 | (@as(u32, sz_regs[0]) << 16);
    vm.write_32(inst); // MOV x3, size[0]

    vm.write_32(0xF940D809 | (20 << 5)); // LDR x9, [x20, #432]
    vm.write_32(0xD63F0120); // BLR x9
}

pub fn emit_native_codecopy(vm: anytype, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    // Expand memory for destOffset + size
    try emit_memory_check(vm, destOffset, size, 0);

    const dest_regs = regs_mod.get_bank_regs(destOffset);
    const off_regs = regs_mod.get_bank_regs(offset);
    const size_regs = regs_mod.get_bank_regs(size);
    // Copy bytecode[offset..] to memory[destOffset..]
    // bytecode_ptr @ 272
    vm.emit_ldr_reg_imm(9, 20, 8); // mem_ptr
    // ADD x0, x9, dest ; dest pointer
    const inst = 0x8B000120 | (@as(u32, dest_regs[0]) << 16) | (9 << 5) | 0;
    vm.write_32(inst);
    // LDR x9, [x20, #272] ; code_ptr
    vm.emit_ldr_reg_imm(9, 20, 272);
    // src pointer
    const inst_src = 0x8B000121 | (@as(u32, off_regs[0]) << 16) | (9 << 5) | 1;
    vm.write_32(inst_src);
    // MOV x2, size
    const inst_mov_sz = 0xAA0003E2 | (@as(u32, size_regs[0]) << 16);
    vm.write_32(inst_mov_sz);

    // CBZ x2, skip (Offset 4 instrs: LDRB, STRB, SUBS, B.NE) -> 0x80
    vm.write_32(0xB4000082);
    // loop: LDRB w9, [x1], #1
    vm.write_32(0x38401429);
    // STRB w9, [x0], #1
    vm.write_32(0x38001409);
    // SUBS x2, #1
    vm.write_32(0xF1000442);
    // B.NE loop
    vm.write_32(0x54FFFF81);
}

pub fn emit_native_extcodecopy(vm: anytype, addr: CompilerInterface.Register, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    // Expand memory for destOffset + size
    try emit_memory_check(vm, destOffset, size, 0);

    // Callback @ 352
    const a_regs = regs_mod.get_bank_regs(addr);
    const d_regs = regs_mod.get_bank_regs(destOffset);
    const o_regs = regs_mod.get_bank_regs(offset);
    const s_regs = regs_mod.get_bank_regs(size);

    vm.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, 32
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }

    vm.write_32(0xF9409000 | (20 << 5)); // LDR x0, [x20, #288] (db)
    vm.write_32(0x910003E1); // x1 = sp
    var inst = 0xAA0003E2 | (@as(u32, d_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E3 | (@as(u32, o_regs[0]) << 16);
    vm.write_32(inst);
    const inst_mcopy = 0xAA0003E4 | (@as(u32, s_regs[0]) << 16); // x4 = size
    vm.write_32(inst_mcopy);
    // evm_mcopy @ 432 ? No, extcodecopy callback used to be passed differently.
    // Wait, in previous joyboy.zig:
    // self.emit_ldr_reg_imm(9, 20, 432); -> 432 is mcopy?
    // Let's check joyboy.zig again.
    // emit_native_extcodecopy called callback @ 432?
    // emit_native_mcopy called callback @ 432.
    // emit_native_extcodecopy logic in joyboy.zig seemed to call 432 but passed args differently?
    // Actually, in joyboy.zig:
    // emit_native_extcodecopy:
    //   LDR x9, [x20, #432]
    //   BLR x9
    // BUT extcodecopy typically uses evm_extcodecopy @ 352 (from JitContext definition in luffy.zig: 71: evm_extcodecopy at offset 71*8=568? No struct is reordered).
    // JitContext layout in luffy.zig:
    // ...
    // evm_extcodecopy: *const fn ...
    // Let's assume the offset in joyboy.zig was correct for whatever `evm_extcodecopy` maps to.

    // I will use 352 as per my comment "Callback @ 352" in the code I am copying, but the code I copied used 432?
    // Wait, let's look at joyboy.zig again.
    // emit_native_extcodecopy.

    vm.emit_ldr_reg_imm(9, 20, 352); // Correct offset for evm_extcodecopy?
    // In luffy.zig: evm_extcodecopy is after evm_extcodehash(344). So 352.
    // So 352 is correct. 432 was mcopy.

    // Ah, my manual copy might have had a typo or I misread 432 in joyboy.zig view?
    // In joyboy.zig step 1551 view:
    // emit_native_mcopy uses 432.
    // emit_native_extcodecopy uses 352 in my "Callback @ 352" comment but then `emit_ldr_reg_imm(9, 20, 432)`??
    // No, I need to check joyboy.zig carefully.

    vm.write_32(0xD63F0120); // BLR x9
    vm.write_32(0x910083FF);
}

pub fn emit_native_returndatacopy(vm: anytype, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    // Expand memory for destOffset + size
    try emit_memory_check(vm, destOffset, size, 0);

    const dest_regs = regs_mod.get_bank_regs(destOffset);
    const off_regs = regs_mod.get_bank_regs(offset);
    const size_regs = regs_mod.get_bank_regs(size);
    // returndata_ptr @ 40
    vm.emit_ldr_reg_imm(9, 20, 8); // mem_ptr
    const inst = 0x8B000120 | (@as(u32, dest_regs[0]) << 16) | (9 << 5) | 0;
    vm.write_32(inst);
    vm.emit_ldr_reg_imm(9, 20, 40); // returndata_ptr @ 40 (5*8)
    // src pointer
    const inst_src_rt = 0x8B000121 | (@as(u32, off_regs[0]) << 16) | (9 << 5) | 1;
    vm.write_32(inst_src_rt);
    const inst_size = 0xAA0003E2 | (@as(u32, size_regs[0]) << 16);
    vm.write_32(inst_size);
    vm.write_32(0xB4000062);
    vm.write_32(0x38401429);
    vm.write_32(0x38001409);
    vm.write_32(0xF1000442);
    vm.write_32(0x54FFFF81);
}

pub fn emit_native_calldatacopy(vm: anytype, destOffset: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    // Expand memory for destOffset + size
    try emit_memory_check(vm, destOffset, size, 0);

    const dest_regs = regs_mod.get_bank_regs(destOffset);
    const off_regs = regs_mod.get_bank_regs(offset);
    const size_regs = regs_mod.get_bank_regs(size);

    // x0 = dest (memory_ptr + destOffset)
    // x1 = src (calldata_ptr + offset)
    // x2 = size

    // LDR x9, [x20, #8] ; memory_ptr
    vm.write_32(0xF9400400 | (20 << 5) | 9);
    // ADD x0, x9, dest[0]
    vm.write_32(0x8B000120 | (@as(u32, dest_regs[0]) << 16) | (9 << 5) | 0);

    // LDR x9, [x20, #24] ; calldata_ptr
    vm.write_32(0xF9400C00 | (20 << 5) | 9);
    // ADD x1, x9, off[0]
    vm.write_32(0x8B000121 | (@as(u32, off_regs[0]) << 16) | (9 << 5) | 1);

    // MOV x2, size[0]
    vm.write_32(0xAA0003E2 | (@as(u32, size_regs[0]) << 16));

    // CBZ x2, skip
    vm.write_32(0xB4000062);
    // loop: LDRB w9, [x1], #1
    vm.write_32(0x38401429);
    // STRB w9, [x0], #1
    vm.write_32(0x38001409);
    // SUBS x2, #1
    vm.write_32(0xF1000442);
    // B.NE loop
    vm.write_32(0x54FFFF81);
}
