const std = @import("std");
const regs_mod = @import("registers.zig");
const interface = @import("../compiler_interface.zig");
const CompilerInterface = interface.CompilerInterface;

pub fn get_virtual_slot(self: anytype, stack_idx: usize) CompilerInterface.VirtualSlot {
    if (stack_idx >= self.virtual_stack.items.len) return .memory;
    return self.virtual_stack.items[stack_idx];
}

pub fn push_virtual_constant(self: anytype, val: u256) !void {
    try self.virtual_stack.append(self.allocator, .{ .constant = val });
}

pub fn push_virtual_memory(self: anytype) !void {
    try self.virtual_stack.append(self.allocator, .memory);
}

pub fn push_virtual_register(self: anytype, reg: CompilerInterface.Register) !void {
    try self.virtual_stack.append(self.allocator, .{ .register = reg });
}

pub fn pop_virtual(self: anytype, n: usize) void {
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

pub fn sync_virtual_stack(self: anytype, stack_top: u64) !void {
    const len = self.virtual_stack.items.len;
    if (stack_top < len) {
        const n = len - @as(usize, @intCast(stack_top));
        pop_virtual(self, n);
    } else if (stack_top > len) {
        const diff = @as(usize, @intCast(stack_top)) - len;
        try self.virtual_stack.ensureUnusedCapacity(self.allocator, diff);
        for (0..diff) |_| {
            self.virtual_stack.appendAssumeCapacity(.memory);
        }
    }
}

pub fn materialize_slot(self: anytype, stack_idx: usize) !void {
    const slot = &self.virtual_stack.items[stack_idx];

    switch (slot.*) {
        .constant => |val| {
            const bank = try allocate_bank(self, stack_idx);
            const regs = regs_mod.get_bank_regs(bank);
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
            const bank = try allocate_bank(self, stack_idx);
            try self.emit_load_u256_from_stack(bank, stack_idx);
            slot.* = .{ .register = bank };
            self.register_banks[bank].locked = true; // Lock for this instruction
        },
        .register => |bank| {
            self.register_banks[bank].locked = true; // Ensure it's locked
        },
    }
}

pub fn compile_move(self: anytype, dst_idx: u64, src_idx: u64) !void {
    const src_sidx = @as(usize, @intCast(src_idx));
    const dst_sidx = @as(usize, @intCast(dst_idx));

    try materialize_slot(self, src_sidx);
    const slot = get_virtual_slot(self, src_sidx);
    const src_bank = slot.register; // Should be register after materialize

    // Allocate dest bank
    const dst_bank = try allocate_bank(self, dst_sidx);

    const src_regs = regs_mod.get_bank_regs(src_bank);
    const dst_regs = regs_mod.get_bank_regs(dst_bank);

    // Chain 4 MOVs: ORR dst, XZR, src
    inline for (0..4) |i| {
        const inst = 0xAA000000 | (@as(u32, src_regs[i]) << 16) | (31 << 5) | @as(u32, dst_regs[i]);
        self.write_32(inst);
    }
    self.virtual_stack.items[dst_sidx] = .{ .register = dst_bank };
    unlock_all_banks(self);
}

pub fn compile_swap(self: anytype, idx1: u64, idx2: u64) !void {
    const s1 = @as(usize, @intCast(idx1));
    const s2 = @as(usize, @intCast(idx2));

    // Materialize both slots to registers to ensure they are movable
    try materialize_slot(self, s1);
    try materialize_slot(self, s2);

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
    unlock_all_banks(self);
}

pub fn compile_push(self: anytype, stack_idx: u64, value: u256) !void {
    _ = self;
    _ = stack_idx;
    _ = value;
    // Stub
}

pub fn compile_pop(self: anytype, stack_idx: u64) !void {
    _ = self;
    _ = stack_idx;
    // Stub
}

pub fn allocate_bank(self: anytype, stack_idx: usize) !CompilerInterface.Register {
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
        try emit_spill_bank(self, @intCast(v_idx));

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

fn emit_spill_bank(self: anytype, bank_idx: u8) !void {
    const regs = regs_mod.get_bank_regs(bank_idx);
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

pub fn unlock_all_banks(self: anytype) void {
    for (&self.register_banks) |*r| {
        r.locked = false;
    }
}
