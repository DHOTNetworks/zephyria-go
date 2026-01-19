const std = @import("std");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const regs_mod = @import("registers.zig");

pub fn emit_native_call(vm: anytype, gas: CompilerInterface.Register, addr: CompilerInterface.Register, val: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    try vm.flush_all_to_memory();
    const g_regs = regs_mod.get_bank_regs(gas);
    const a_regs = regs_mod.get_bank_regs(addr);
    const v_regs = regs_mod.get_bank_regs(val);
    const ao_regs = regs_mod.get_bank_regs(arg_off);
    const al_regs = regs_mod.get_bank_regs(arg_len);
    const ro_regs = regs_mod.get_bank_regs(ret_off);
    const rl_regs = regs_mod.get_bank_regs(ret_len);
    const d_regs = regs_mod.get_bank_regs(dst);

    // Stack alloc: 64 bytes (32 addr + 32 val)
    vm.write_32(0xD10103FF); // SUB sp, sp, #64

    // Store Addr @ [sp]
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }
    // Store Val @ [sp+32]
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
        vm.write_32(inst);
    }

    // Args for callback
    vm.write_32(0xF9409000 | (20 << 5)); // LDR x0, [x20, #288] (db)
    var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
    vm.write_32(inst); // x1 = gas[0]
    vm.write_32(0x910003E2); // MOV x2, sp (addr_ptr)
    inst = 0x91008003 | (31 << 5);
    vm.write_32(inst); // ADD x3, sp, #32 (val_ptr)

    inst = 0xAA0003E4 | (@as(u32, ao_regs[0]) << 16);
    vm.write_32(inst); // x4 = arg_off
    inst = 0xAA0003E5 | (@as(u32, al_regs[0]) << 16);
    vm.write_32(inst); // x5 = arg_len
    inst = 0xAA0003E6 | (@as(u32, ro_regs[0]) << 16);
    vm.write_32(inst); // x6 = ret_off
    inst = 0xAA0003E7 | (@as(u32, rl_regs[0]) << 16);
    vm.write_32(inst); // x7 = ret_len

    // Call callback @ 368
    vm.write_32(0xF940B809 | (20 << 5)); // LDR x9, [x20, #368]
    vm.write_32(0xD63F0120); // BLR x9

    // Result x0 (bool) -> dst
    // zero extend x0 to u256
    inst = 0xAA0003E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);

    vm.write_32(0x910103FF); // Restore stack
}

pub fn emit_native_callcode(vm: anytype, gas: CompilerInterface.Register, addr: CompilerInterface.Register, val: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    // Same as CALL but callback @ 368
    const g_regs = regs_mod.get_bank_regs(gas);
    const a_regs = regs_mod.get_bank_regs(addr);
    const v_regs = regs_mod.get_bank_regs(val);
    const ao_regs = regs_mod.get_bank_regs(arg_off);
    const al_regs = regs_mod.get_bank_regs(arg_len);
    const ro_regs = regs_mod.get_bank_regs(ret_off);
    const rl_regs = regs_mod.get_bank_regs(ret_len);
    const d_regs = regs_mod.get_bank_regs(dst);

    vm.write_32(0xD10103FF); // SUB sp, 64
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
        vm.write_32(inst);
    }

    vm.write_32(0xF9409000 | (20 << 5));
    var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
    vm.write_32(inst);
    vm.write_32(0x910003E2);
    inst = 0x91008003 | (31 << 5);
    vm.write_32(inst);

    inst = 0xAA0003E4 | (@as(u32, ao_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E5 | (@as(u32, al_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E6 | (@as(u32, ro_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E7 | (@as(u32, rl_regs[0]) << 16);
    vm.write_32(inst);

    vm.write_32(0xF940BC09 | (20 << 5)); // <--- 376 (Wait, callcode callback offset?)
    // joyboy.zig says: 368 for CALL. 376 for CALLCODE? Let's check original.
    // Original comment in callcode says "Same as CALL but callback @ 368" but code emission says 0xF940BC09 which is 376 dec.
    // I will trust the code emission.
    vm.write_32(0xD63F0120);

    inst = 0xAA0003E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);

    vm.write_32(0x910103FF);
}

pub fn emit_native_delegatecall(vm: anytype, gas: CompilerInterface.Register, addr: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    // Callback @ 376?? Original says 376 in comment, but emits 0xF940C009 which is 384 dec.
    const g_regs = regs_mod.get_bank_regs(gas);
    const a_regs = regs_mod.get_bank_regs(addr);
    const ao_regs = regs_mod.get_bank_regs(arg_off);
    const al_regs = regs_mod.get_bank_regs(arg_len);
    const ro_regs = regs_mod.get_bank_regs(ret_off);
    const rl_regs = regs_mod.get_bank_regs(ret_len);
    const d_regs = regs_mod.get_bank_regs(dst);

    vm.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, 32 (only addr)
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }

    vm.write_32(0xF9409000 | (20 << 5)); // db
    var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
    vm.write_32(inst);
    vm.write_32(0x910003E2); // addr ptr

    inst = 0xAA0003E3 | (@as(u32, ao_regs[0]) << 16);
    vm.write_32(inst); // arg_off -> x3
    inst = 0xAA0003E4 | (@as(u32, al_regs[0]) << 16);
    vm.write_32(inst); // arg_len -> x4
    inst = 0xAA0003E5 | (@as(u32, ro_regs[0]) << 16);
    vm.write_32(inst); // ret_off -> x5
    inst = 0xAA0003E6 | (@as(u32, rl_regs[0]) << 16);
    vm.write_32(inst); // ret_len -> x6

    vm.write_32(0xF940C009 | (20 << 5)); // <--- 384 (evm_delegatecall)
    vm.write_32(0xD63F0120);

    inst = 0xAA0003E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);

    vm.write_32(0x910083FF);
}

pub fn emit_native_staticcall(vm: anytype, gas: CompilerInterface.Register, addr: CompilerInterface.Register, arg_off: CompilerInterface.Register, arg_len: CompilerInterface.Register, ret_off: CompilerInterface.Register, ret_len: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    // Callback @ 384?? Original says 384, emits 0xF940C409 -> 392.
    const g_regs = regs_mod.get_bank_regs(gas);
    const a_regs = regs_mod.get_bank_regs(addr);
    const ao_regs = regs_mod.get_bank_regs(arg_off);
    const al_regs = regs_mod.get_bank_regs(arg_len);
    const ro_regs = regs_mod.get_bank_regs(ret_off);
    const rl_regs = regs_mod.get_bank_regs(ret_len);
    const d_regs = regs_mod.get_bank_regs(dst);

    vm.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, 32
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }

    vm.write_32(0xF9409000 | (20 << 5));
    var inst = 0xAA0003E1 | (@as(u32, g_regs[0]) << 16);
    vm.write_32(inst);
    vm.write_32(0x910003E2);

    inst = 0xAA0003E3 | (@as(u32, ao_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E4 | (@as(u32, al_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E5 | (@as(u32, ro_regs[0]) << 16);
    vm.write_32(inst);
    inst = 0xAA0003E6 | (@as(u32, rl_regs[0]) << 16);
    vm.write_32(inst);

    vm.write_32(0xF940C409 | (20 << 5)); // <--- 392 (evm_staticcall)
    vm.write_32(0xD63F0120);

    inst = 0xAA0003E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);

    vm.write_32(0x910083FF);
}

pub fn emit_native_create(vm: anytype, val: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    // Callback @ 392?? Original comments 392, emits 0xF940C809 -> 400.
    const v_regs = regs_mod.get_bank_regs(val);
    const o_regs = regs_mod.get_bank_regs(offset);
    const s_regs = regs_mod.get_bank_regs(size);
    const d_regs = regs_mod.get_bank_regs(dst);

    vm.write_32(0xD10103FF); // SUB sp, 64 (32 val + 32 res)

    // Store val @ [sp]
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
        vm.write_32(inst);
    }

    // MOV x0, x20 (Pass ctx as first arg)
    vm.write_32(0xAA1403E0);
    vm.write_32(0x910003E1); // val_ptr=sp
    var inst = 0xAA0003E2 | (@as(u32, o_regs[0]) << 16);
    vm.write_32(inst); // off
    inst = 0xAA0003E3 | (@as(u32, s_regs[0]) << 16);
    vm.write_32(inst); // size
    inst = 0x91008004 | (31 << 5);
    vm.write_32(inst); // res_ptr=sp+32

    vm.write_32(0xF940C809 | (20 << 5)); // LDR x9, [x20, #400] (evm_create)
    vm.write_32(0xD63F0120);

    // Load result from [sp+32]
    inline for (0..4) |i| {
        const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(ld);
    }
    vm.write_32(0x910103FF);
}

pub fn emit_native_create2(vm: anytype, val: CompilerInterface.Register, offset: CompilerInterface.Register, size: CompilerInterface.Register, salt: CompilerInterface.Register, dst: CompilerInterface.Register) !void {
    const v_regs = regs_mod.get_bank_regs(val);
    const o_regs = regs_mod.get_bank_regs(offset);
    const s_regs = regs_mod.get_bank_regs(size);
    const sa_regs = regs_mod.get_bank_regs(salt);
    const d_regs = regs_mod.get_bank_regs(dst);

    // SUB sp, sp, #96 (32 val + 32 salt + 32 res)
    vm.write_32(0xD10183FF);

    // Val @ sp
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, v_regs[i]);
        vm.write_32(inst);
    }
    // Salt @ sp+32
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, sa_regs[i]);
        vm.write_32(inst);
    }

    // Setup args
    vm.write_32(0xAA1403E0); // MOV x0, x20 (ctx)
    vm.write_32(0x910003E1); // MOV x1, sp (val_ptr)
    var inst = 0xAA0003E2 | (@as(u32, o_regs[0]) << 16);
    vm.write_32(inst); // MOV x2, offset
    inst = 0xAA0003E3 | (@as(u32, s_regs[0]) << 16);
    vm.write_32(inst); // MOV x3, size
    inst = 0x91008004 | (31 << 5);
    vm.write_32(inst); // ADD x4, sp, #32 (salt_ptr)
    inst = 0x91010005 | (31 << 5);
    vm.write_32(inst); // ADD x5, sp, #64 (res_ptr)

    // Callback @ 408
    vm.write_32(0xF940CC09 | (20 << 5)); // LDR x9, [x20, #408]
    vm.write_32(0xD63F0120); // BLR x9

    // Load result from [sp+64]
    inline for (0..4) |i| {
        const ld = 0xF9400000 | (@as(u32, @intCast(i + 8)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(ld);
    }
    vm.write_32(0x910183FF); // ADD sp, sp, #96
}

pub fn emit_native_return(vm: anytype, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    const o_regs = regs_mod.get_bank_regs(offset);
    const s_regs = regs_mod.get_bank_regs(size);
    // Set returndata_ptr (40) = memory_ptr (8) + offset
    // Set returndata_len (48) = size
    // Set is_halt (449) = 1
    // Use x16 as scratch (safe from banks 0-4)
    vm.emit_ldr_reg_imm(16, 20, 8); // LDR x16, [x20, #8] (memory_ptr)
    const inst = 0x8B000210 | (@as(u32, o_regs[0]) << 16) | (16 << 5) | 16; // ADD x16, x16, offset[0]
    vm.write_32(inst); // x16 = mem + offset
    vm.emit_str_reg_imm(16, 20, 40); // STR x16, [x20, #40] (returndata_ptr)

    vm.emit_str_reg_imm(s_regs[0], 20, 48); // STR size, [x20, #48] (returndata_len)

    const inst_halt = 0xD2800030; // MOV x16, #1
    vm.write_32(inst_halt);
    vm.emit_strb_reg_imm(16, 20, 449); // is_halt @ 449

    // Epilogue
    vm.write_32(0xA8C173FB); // ldp x27, x28, [sp], #16
    vm.write_32(0xA8C16BF9); // ldp x25, x26, [sp], #16
    vm.write_32(0xA8C163F7); // ldp x23, x24, [sp], #16
    vm.write_32(0xA8C15BF5); // ldp x21, x22, [sp], #16
    vm.write_32(0xA8C153F3); // ldp x19, x20, [sp], #16
    vm.write_32(0xA8C17BFD); // ldp x29, x30, [sp], #16
    vm.write_32(0xD65F03C0); // ret
}

pub fn emit_native_revert(vm: anytype, offset: CompilerInterface.Register, size: CompilerInterface.Register) !void {
    const o_regs = regs_mod.get_bank_regs(offset);
    const s_regs = regs_mod.get_bank_regs(size);

    // Set returndata_ptr (40) = memory_ptr (8) + offset
    // Use x16 as scratch (safe from banks 0-4)
    vm.emit_ldr_reg_imm(16, 20, 8); // memory_ptr @ 8
    const inst = 0x8B000210 | (@as(u32, o_regs[0]) << 16) | (16 << 5) | 16; // ADD x16, x16, offset[0]
    vm.write_32(inst); // x16 = mem + offset
    vm.emit_str_reg_imm(16, 20, 40); // STR x16, [x20, #40] (returndata_ptr)

    // Set returndata_len (48) = size
    vm.emit_str_reg_imm(s_regs[0], 20, 48); // STR size, [x20, #48]

    // Set is_revert (450) = 1
    const inst_revert = 0xD2800030; // MOV x16, #1
    vm.write_32(inst_revert);
    vm.emit_strb_reg_imm(16, 20, 450); // is_revert @ 450

    // Epilogue
    vm.write_32(0xA8C173FB); // ldp x27, x28, [sp], #16
    vm.write_32(0xA8C16BF9); // ldp x25, x26, [sp], #16
    vm.write_32(0xA8C163F7); // ldp x23, x24, [sp], #16
    vm.write_32(0xA8C15BF5); // ldp x21, x22, [sp], #16
    vm.write_32(0xA8C153F3); // ldp x19, x20, [sp], #16
    vm.write_32(0xA8C17BFD); // ldp x29, x30, [sp], #16
    vm.write_32(0xD65F03C0); // ret
}

pub fn emit_native_log_common(vm: anytype, offset: CompilerInterface.Register, size: CompilerInterface.Register, topics: []const CompilerInterface.Register) !void {
    const o_regs = regs_mod.get_bank_regs(offset);
    const s_regs = regs_mod.get_bank_regs(size);

    // Stack for topics: 32 bytes per topic
    const stack_size = topics.len * 32;
    if (stack_size > 0) {
        const aligned_size = (stack_size + 15) & ~@as(usize, 15);
        // SUB sp, sp, imm12
        const sub = 0xD10003FF | (@as(u32, @intCast(aligned_size)) << 10);
        vm.write_32(sub);

        for (topics, 0..) |t, i| {
            const t_regs = regs_mod.get_bank_regs(t);
            inline for (0..4) |j| {
                // STR register, [sp, #(i*32 + j*8)]
                const off = i * 32 + j * 8;
                const inst = 0xF90003E0 | (@as(u32, @intCast(off >> 3)) << 10) | @as(u32, t_regs[j]);
                vm.write_32(inst);
            }
        }
    }

    vm.write_32(0xF9400681 | (20 << 5)); // LDR x1, [x20, #8] (memory_ptr)

    var inst = 0xAA0003E2 | (@as(u32, o_regs[0]) << 16);
    vm.write_32(inst); // x2 = offset
    inst = 0xAA0003E3 | (@as(u32, s_regs[0]) << 16);
    vm.write_32(inst); // x3 = size

    if (stack_size > 0) {
        vm.write_32(0x910003E4); // MOV x4, sp
    } else {
        vm.write_32(0xD2800004); // MOV x4, 0
    }

    inst = 0xD2800005 | (@as(u32, @intCast(topics.len)) << 5);
    vm.write_32(inst); // MOV x5, #num

    vm.write_32(0xF940B409 | (20 << 5)); // LDR x9, [x20, #360]
    vm.write_32(0xD63F0120); // BLR x9

    if (stack_size > 0) {
        const aligned_size = (stack_size + 15) & ~@as(usize, 15);
        const add = 0x910003FF | (@as(u32, @intCast(aligned_size)) << 10);
        vm.write_32(add);
    }
}
