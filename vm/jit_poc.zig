const std = @import("std");
const EVM = @import("main.zig").EVM;
const Opcode = @import("main.zig").Opcode;
const Allocator = std.mem.Allocator;
const BigInt = @import("core").BigInt;

/// Virtual Register ID
const VReg = u16;

/// Instruction in Register IR
pub const JitOp = union(enum) {
    /// Native Register Operations
    ADD: struct { dst: VReg, src1: VReg, src2: VReg },
    PUSH: struct { dst: VReg, val: u256 },

    /// Fallback to interpreted opcode (Spill/Fill)
    NATIVE: struct {
        op: Opcode,
        inputs: []const VReg, // Registers to push to stack
        output: ?VReg, // Register to pop result into
    },
};

pub const JitBlock = struct {
    ops: std.ArrayListUnmanaged(JitOp),
    allocator: Allocator,
    gas_cost: u64,

    pub fn init(allocator: Allocator) JitBlock {
        return JitBlock{
            .ops = .{},
            .allocator = allocator,
            .gas_cost = 0,
        };
    }

    pub fn deinit(self: *JitBlock) void {
        // The NATIVE variant's `inputs` is a slice `[]const VReg`.
        // If these slices were allocated by `self.allocator`, they need to be freed.
        // The original code used `self.ops.allocator.free(n.inputs)`, which implies the `ArrayList`'s allocator was used.
        // With `ArrayListUnmanaged`, the `JitBlock`'s `allocator` should be used for any allocations it manages.
        // Assuming `n.inputs` are allocated by `self.allocator` when `NATIVE` ops are created.
        for (self.ops.items) |op| {
            switch (op) {
                .NATIVE => |n| self.allocator.free(n.inputs),
                else => {},
            }
        }
        self.ops.deinit(self.allocator);
    }

    pub fn add(self: *JitBlock, op: JitOp) !void {
        try self.ops.append(self.allocator, op);
    }
};

pub const JitCompiler = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) JitCompiler {
        return JitCompiler{
            .allocator = allocator,
        };
    }

    /// Analyze converts Stack Bytecode -> Register IR
    /// Analyze converts Stack Bytecode -> Register IR
    pub fn analyze(self: *JitCompiler, bytecode: []const u8) !std.ArrayListUnmanaged(JitBlock) {
        var blocks = std.ArrayListUnmanaged(JitBlock){};
        errdefer blocks.deinit(self.allocator);

        var current_block = JitBlock.init(self.allocator);
        std.debug.print("[JIT] Starting Analysis for code len: {d}\n", .{bytecode.len});

        // Virtual Stack to track register mappings (Virtual Stack Item -> Register ID)
        var v_stack = std.ArrayListUnmanaged(VReg){};
        defer v_stack.deinit(self.allocator);

        var reg_counter: VReg = 0;

        var pc: usize = 0;
        while (pc < bytecode.len) {
            const opcode_byte = bytecode[pc];
            var op: Opcode = .STOP;
            if (opcode_byte <= @intFromEnum(Opcode.SELFDESTRUCT)) {
                op = @as(Opcode, @enumFromInt(opcode_byte));
            } else {
                op = .INVALID;
            }
            pc += 1;

            // Standard Opcode Costs (Simplified for PoC)
            current_block.gas_cost += 3;

            switch (op) {
                .PUSH1 => {
                    if (pc >= bytecode.len) break;
                    const val = bytecode[pc];
                    pc += 1;

                    const dst = reg_counter;
                    try v_stack.append(self.allocator, dst);
                    reg_counter += 1;

                    try current_block.add(JitOp{ .PUSH = .{ .dst = dst, .val = val } });
                },
                .ADD => {
                    if (v_stack.items.len < 2) return error.StackUnderflow;
                    const src1 = v_stack.pop().?;
                    const src2 = v_stack.pop().?;

                    const dst = reg_counter;
                    reg_counter += 1;

                    try current_block.add(JitOp{ .ADD = .{ .dst = dst, .src1 = src1, .src2 = src2 } });
                    try v_stack.append(self.allocator, dst);
                },
                // Fallback for everything else
                else => {
                    // Determine inputs/outputs (Simplified: Opcode Cost Table needed)
                    // For PoC, assume 0 inputs 0 outputs for unknown ops or just fail
                    // In real impl, we need a table of (inputs, outputs) per opcode

                    // Let's implement STOP as terminator
                    if (op == .STOP) {
                        break;
                    }
                },
            }
        }

        try blocks.append(self.allocator, current_block);
        return blocks;
    }

    /// Execute runs the JIT blocks
    pub fn execute(self: *JitCompiler, evm: *EVM, blocks: []JitBlock) !void {
        // Register File
        var registers = std.AutoHashMap(VReg, BigInt).init(self.allocator);
        defer registers.deinit();

        for (blocks) |block| {
            try evm.consumeGas(block.gas_cost);

            for (block.ops.items) |op| {
                switch (op) {
                    .PUSH => |p| {
                        const v = p.val;
                        const b = BigInt{ .data = .{
                            @truncate(v),
                            @truncate(v >> 64),
                            @truncate(v >> 128),
                            @truncate(v >> 192),
                        } };
                        try registers.put(p.dst, b);
                    },
                    .ADD => |a| {
                        const v1 = registers.get(a.src1) orelse BigInt.init(0);
                        const v2 = registers.get(a.src2) orelse BigInt.init(0);
                        try registers.put(a.dst, v1.add(v2)); // assumes BigInt has add
                    },
                    .NATIVE => |n| {
                        // Spill inputs
                        for (n.inputs) |reg| {
                            const val = registers.get(reg) orelse BigInt.init(0);
                            try evm.stack.push(evm.allocator, val);
                        }

                        // Execute Native
                        const impl = evm.opcodes.get(n.op) orelse return error.UnknownOpcode;
                        try impl.execute(evm);

                        // Fill output
                        if (n.output) |out_reg| {
                            if (evm.stack.pop()) |val| {
                                try registers.put(out_reg, val);
                            } else return error.StackUnderflow;
                        }
                    },
                }
            }
        }
    }
};
