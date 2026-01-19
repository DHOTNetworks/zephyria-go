const std = @import("std");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;
const regs_mod = @import("registers.zig");

// --- Context Reads ---

pub fn emit_native_address(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // x20 = JitContext, address at offset 56 (20 bytes + pad -> 24)
    var inst: u32 = 0xF9401C00 | (20 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xF9402000 | (20 << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xF9402400 | (20 << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_caller(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // x20 = JitContext, caller at offset 80
    var inst: u32 = 0xF9402800 | (20 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xF9402C00 | (20 << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xF9403000 | (20 << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_origin(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // x20 = JitContext, origin at offset 104
    var inst: u32 = 0xF9403400 | (20 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xF9403800 | (20 << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xF9403C00 | (20 << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_callvalue(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // x20 = JitContext, call_value at offset 128
    var inst: u32 = 0xF9404000 | (20 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xF9404400 | (20 << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xF9404800 | (20 << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xF9404C00 | (20 << 5) | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_balance(vm: anytype, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const a_regs = regs_mod.get_bank_regs(addr);

    // Call evm_balance @ 320
    vm.write_32(0xD10103FF); // SUB sp, sp, #64

    // Store addr @ sp
    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }

    vm.write_32(0xF9409000 | (20 << 5)); // db
    vm.write_32(0x910003E1); // addr ptr
    const inst = 0x91008002 | (31 << 5);
    vm.write_32(inst); // res ptr

    vm.write_32(0xF940A009 | (20 << 5)); // evm_balance
    vm.write_32(0xD63F0120);

    inline for (0..4) |i| {
        const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(ld);
    }
    vm.write_32(0x910103FF);
}

pub fn emit_native_blockhash(vm: anytype, dst: CompilerInterface.Register, num: CompilerInterface.Register) !void {
    try vm.flush_all_to_memory();
    const d_regs = regs_mod.get_bank_regs(dst);
    const n_regs = regs_mod.get_bank_regs(num);

    // Call evm_blockhash @ 328
    vm.write_32(0xD10103FF); // SUB sp, #64

    inline for (0..4) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, n_regs[i]);
        vm.write_32(inst);
    }

    vm.write_32(0xF9409000 | (20 << 5)); // db
    vm.write_32(0x910003E1); // num ptr
    const inst = 0x91008002 | (31 << 5);
    vm.write_32(inst); // res ptr

    vm.write_32(0xF940A409 | (20 << 5)); // evm_blockhash
    vm.write_32(0xD63F0120);

    inline for (0..4) |i| {
        const ld = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(ld);
    }
    vm.write_32(0x910103FF);
}

pub fn emit_native_chainid(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // chain_id @ 160 (8 bytes)
    // LDR x0, [x20, #160]
    vm.write_32(0xF9405000 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        const inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_gasprice(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // gas_price @ 192 (8 bytes? wait, gasprice is u256 potentially, but usually fits in u64. JitContext says 8 bytes?)
    // Layout: +192: gas_price (8).
    // So it is u64.
    vm.write_32(0xF9406000 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        const inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_gaslimit(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // gas_limit @ 184 (8 bytes)
    vm.write_32(0xF9405C00 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        const inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_timestamp(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // timestamp @ 176 (8 bytes)
    vm.write_32(0xF9405800 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        const inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_number(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // block_number @ 168 (8 bytes)
    vm.write_32(0xF9405400 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        const inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_basefee(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // base_fee @ 200 (8 bytes)
    vm.write_32(0xF9406400 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        const inst = 0xD2800000 | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_difficulty(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // difficulty -> prevrandao @ 208 (32 bytes)
    // 208
    var inst: u32 = 0xF9406800 | (20 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xF9406C00 | (20 << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xF9407000 | (20 << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xF9407400 | (20 << 5) | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

pub fn emit_native_prevrandao(vm: anytype, dst: CompilerInterface.Register) !void {
    try emit_native_difficulty(vm, dst);
}

pub fn emit_native_coinbase(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // coinbase @ 240
    var inst: u32 = 0xF9407800 | (20 << 5) | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xF9407C00 | (20 << 5) | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xF9408000 | (20 << 5) | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);
}

// Calldata / Code ops

pub fn emit_native_codesize(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // Check if code copy implementation uses a register?
    // JoyboyVM.code_size is passed in init, not in JitContext?
    // wait, context usually has bytecode_len @ 280
    // LDR x0, [x20, #280]
    vm.write_32(0xF9408C00 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        vm.write_32(0xD2800000 | @as(u32, d_regs[i]));
    }
}

pub fn emit_native_calldatasize(vm: anytype, dst: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    // calldata_len @ 32
    vm.write_32(0xF9401000 | (20 << 5) | @as(u32, d_regs[0]));
    inline for (1..4) |i| {
        vm.write_32(0xD2800000 | @as(u32, d_regs[i]));
    }
}

pub fn emit_native_calldataload(vm: anytype, dst: CompilerInterface.Register, offset: CompilerInterface.Register) !void {
    const d_regs = regs_mod.get_bank_regs(dst);
    const o_regs = regs_mod.get_bank_regs(offset);

    // x20 = JitContext, calldata_ptr at offset 24, calldata_len at offset 32
    // LDR x9, [x20, #24] ; calldata_ptr
    var inst: u32 = 0xF9400C09 | (20 << 5); // LDR x9, [x20, #24]
    vm.write_32(inst);
    // ADD x9, x9, offset[0] ; ptr + offset
    inst = 0x8B000120 | (@as(u32, o_regs[0]) << 16) | (9 << 5) | 9;
    vm.write_32(inst);
    // Load 32 bytes (4 limbs) - simplified, assumes aligned
    inline for (0..4) |i| {
        inst = 0xF9400000 | (@as(u32, @intCast(i)) << 10) | (9 << 5) | @as(u32, d_regs[3 - i]);
        vm.write_32(inst);
    }
}

pub fn emit_native_extcodesize(vm: anytype, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
    try vm.flush_all_to_memory();
    const d_regs = regs_mod.get_bank_regs(dst);
    const a_regs = regs_mod.get_bank_regs(addr);
    // Callback @ 336
    vm.write_32(0xD1008000 | (31 << 5) | 31); // SUB sp, #32
    inline for (0..3) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }
    // LDR x0, [x20, #288] ; db
    vm.write_32(0xF9409000 | (20 << 5));
    // MOV x1, sp ; addr_ptr
    vm.write_32(0x910003E1);
    // LDR x9, [x20, #336]
    vm.write_32(0xF940A809 | (20 << 5));
    // BLR x9
    vm.write_32(0xD63F0120);
    // Result in x0
    var inst = 0xAA0003E0 | @as(u32, d_regs[0]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[1]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[2]);
    vm.write_32(inst);
    inst = 0xD2800000 | @as(u32, d_regs[3]);
    vm.write_32(inst);
    vm.write_32(0x910083FF);
}

pub fn emit_native_extcodehash(vm: anytype, dst: CompilerInterface.Register, addr: CompilerInterface.Register) !void {
    try vm.flush_all_to_memory();
    const d_regs = regs_mod.get_bank_regs(dst);
    const a_regs = regs_mod.get_bank_regs(addr);
    // Callback @ 344
    vm.write_32(0xD10103FF); // SUB sp, #64
    inline for (0..3) |i| {
        const inst = 0xF9000000 | (@as(u32, @intCast(i)) << 10) | (31 << 5) | @as(u32, a_regs[i]);
        vm.write_32(inst);
    }
    vm.write_32(0xF9409000 | (20 << 5)); // db
    vm.write_32(0x910003E1); // addr
    var inst: u32 = 0x91008002 | (31 << 5);
    vm.write_32(inst); // res_ptr=sp+32
    vm.write_32(0xF940AC09 | (20 << 5)); // callback @ 344
    vm.write_32(0xD63F0120);
    inline for (0..4) |i| {
        inst = 0xF9400000 | (@as(u32, @intCast(i + 4)) << 10) | (31 << 5) | @as(u32, d_regs[i]);
        vm.write_32(inst);
    }
    vm.write_32(0x910103FF);
}
