// File: src/opcodes/jumpi.zig

const std = @import("std");
const EVM = @import("../main.zig").EVM;
const OpcodeImpl = @import("../main.zig").OpcodeImpl;
const Opcode = @import("../main.zig").Opcode;

pub fn getImpl() struct { code: u8, impl: OpcodeImpl } {
    return .{
        .code = @intFromEnum(Opcode.JUMPI),
        .impl = OpcodeImpl{
            .execute = execute,
        },
    };
}

fn execute(evm: *EVM) !void {
    if (evm.stack.pop()) |dest| {
        if (evm.stack.pop()) |cond| {
            if (!cond.isZero()) {
                const dest_pc = @as(usize, @intCast(dest.to(u64)));
                if (dest_pc >= evm.code.len or evm.code[dest_pc] != @intFromEnum(Opcode.JUMPDEST)) {
                    return error.InvalidJumpDest;
                }
                evm.pc = dest_pc;
            }
        } else return error.StackUnderflow;
    } else return error.StackUnderflow;
}

pub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {
    _ = pc;
    _ = bytecode;
    if (stack_top.* < 2) return error.StackUnderflow;
    const cond = stack_top.* - 2;
    // Check for Static Jump (Constant)
    const dest_idx = stack_top.* - 1;
    const dest_slot = jit.get_virtual_slot(dest_idx);
    std.debug.print("[JIT] JUMPI dest_idx={d} slot_type={s}\n", .{ dest_idx, @tagName(dest_slot) });

    if (dest_slot == .constant) {
        const target = @as(usize, @intCast(dest_slot.constant));
        std.debug.print("[JIT] JUMPI target={d} cond_idx={d}\n", .{ target, cond });
        try jit.compile_jumpi(cond, target);

        // JUMPI pops dest + cond
        jit.pop_virtual(2);
        stack_top.* -= 2;
    } else {
        return error.DynamicJumpNotSupported;
    }
}
