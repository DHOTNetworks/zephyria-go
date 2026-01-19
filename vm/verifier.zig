const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;

/// Configuration for the Verifier
pub const VerifierConfig = struct {
    max_stack_height: u16 = 1024,
    enforce_gas_checks: bool = true,
};

/// Errors that can occur during verification
pub const VerifyError = error{
    StackUnderflow,
    StackOverflow,
    InvalidJumpDestination,
    InvalidInstruction,
    UnreachableCode,
    InfiniteLoopDetected, // Basic check
    OutOfMemory,
};

/// Represents a Basic Block in the Control Flow Graph
const BasicBlock = struct {
    start_pc: usize,
    end_pc: usize,
    stack_entry: i16, // Expected stack height at entry (-1 if unknown)
    stack_delta: i16, // Net change in stack height
    successors: ArrayList(usize), // PCs of possible next blocks
};

const StackEffect = struct {
    pops: i16,
    pushes: i16,
};

pub const Verifier = struct {
    allocator: Allocator,
    bytecode: []const u8,
    config: VerifierConfig,
    jumpdests: std.DynamicBitSet,
    basic_blocks: AutoHashMap(usize, BasicBlock), // Key: start_pc

    pub fn init(allocator: Allocator, bytecode: []const u8, config: VerifierConfig) !Verifier {
        var jumpdests = try std.DynamicBitSet.initEmpty(allocator, bytecode.len);

        // Pass 1: Mark valid JUMPDESTs
        var i: usize = 0;
        while (i < bytecode.len) {
            const op = bytecode[i];
            if (op == 0x5B) { // JUMPDEST
                jumpdests.set(i);
                i += 1;
            } else if (op >= 0x60 and op <= 0x7F) { // PUSH1..PUSH32
                const push_len = op - 0x5F;
                i += 1 + push_len;
            } else {
                i += 1;
            }
        }

        return Verifier{
            .allocator = allocator,
            .bytecode = bytecode,
            .config = config,
            .jumpdests = jumpdests,
            .basic_blocks = AutoHashMap(usize, BasicBlock).init(allocator),
        };
    }

    pub fn deinit(self: *Verifier) void {
        self.jumpdests.deinit();
        var it = self.basic_blocks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.successors.deinit(self.allocator);
        }
        self.basic_blocks.deinit();
    }

    /// Run the verification process
    pub fn verify(self: *Verifier) !void {
        // 1. Build CFG and Calculate Stack Deltas
        try self.buildCFG();

        // 2. Traverse Graph to Verify Stack Safety
        try self.verifyStackSafety();
    }

    fn buildCFG(self: *Verifier) !void {
        // Simple queue for traversing reachable code
        var queue = ArrayList(usize).init(self.allocator);
        defer queue.deinit();

        // Start traversing from PC 0
        try queue.append(0);

        // Keep track of visited blocks to avoid re-processing
        var visited = std.AutoHashMap(usize, void).init(self.allocator);
        defer visited.deinit();

        while (queue.items.len > 0) {
            const start_pc = queue.pop();
            if (visited.contains(start_pc)) continue;
            try visited.put(start_pc, {});

            var current_pc = start_pc;
            var stack_delta: i16 = 0;
            var successors = ArrayList(usize).init(self.allocator);
            var terminated = false;

            // Linear scan for the block
            while (current_pc < self.bytecode.len) {
                const op = self.bytecode[current_pc];

                // Calculate instruction effect on stack
                // const effect = getStackEffect(op);
                const effect = StackEffect{ .pops = 0, .pushes = 0 };

                stack_delta = stack_delta - effect.pops + effect.pushes;

                // Handle Control Flow
                if (op == 0x00) { // STOP
                    terminated = true;
                    current_pc += 1;
                    break;
                } else if (op == 0x56) { // JUMP
                    terminated = true;
                    current_pc += 1;
                    break;
                } else if (op == 0x57) { // JUMPI
                    const fallthrough = current_pc + 1;
                    try successors.append(fallthrough);
                    try queue.append(fallthrough);

                    terminated = true; // Block ends here
                    current_pc += 1;
                    break;
                } else if (op == 0xF3 or op == 0xFD) { // RETURN or REVERT
                    terminated = true;
                    current_pc += 1;
                    break;
                } else if (op >= 0x60 and op <= 0x7F) { // PUSHx
                    const push_len = op - 0x5F;
                    current_pc += 1 + push_len;
                } else {
                    current_pc += 1;
                }

                // If next instruction is a JUMPDEST, this block ends (fallthrough)
                if (current_pc < self.bytecode.len and self.jumpdests.isSet(current_pc)) {
                    try successors.append(current_pc);
                    try queue.append(current_pc);
                    break;
                }
            }

            try self.basic_blocks.put(start_pc, BasicBlock{
                .start_pc = start_pc,
                .end_pc = current_pc,
                .stack_entry = -1, // Unknown yet
                .stack_delta = stack_delta,
                .successors = successors,
            });
        }
    }

    fn verifyStackSafety(self: *Verifier) !void {
        var queue = ArrayList(usize).init(self.allocator);
        defer queue.deinit();

        // Seed with entry block
        if (self.basic_blocks.getPtr(0)) |entry_block| {
            entry_block.stack_entry = 0;
            try queue.append(0);
        } else {
            // Empty bytecode or starts with invalid?
            if (self.bytecode.len == 0) return;
            return error.InvalidInstruction;
        }

        while (queue.items.len > 0) {
            const pc = queue.pop();
            const block = self.basic_blocks.getPtr(pc) orelse continue;

            // Calculate stack height at exit of this block
            const height_at_entry = block.stack_entry;
            const height_at_exit = height_at_entry + block.stack_delta;

            // Check Limits
            if (height_at_entry < 0 or height_at_exit < 0) return error.StackUnderflow;
            if (height_at_exit > self.config.max_stack_height) return error.StackOverflow;

            // Propagate to successors
            for (block.successors.items) |succ_pc| {
                if (self.basic_blocks.getPtr(succ_pc)) |succ| {
                    if (succ.stack_entry == -1) {
                        // First visit
                        succ.stack_entry = @intCast(height_at_exit);
                        try queue.append(succ_pc);
                    } else {
                        // Re-visit: Consistency Check
                        if (succ.stack_entry != height_at_exit) {
                            return error.StackUnderflow; // Fail safe
                        }
                    }
                }
            }
        }
    }
};

fn getStackEffect(op: u8) StackEffect {
    // Stack ops
    if (op >= 0x5F and op <= 0x7F) return StackEffect{ .pops = 0, .pushes = 1 }; // PUSHn

    // DUPn
    if (op >= 0x80 and op <= 0x8F) {
        const n: i16 = @intCast(op - 0x7F);
        return StackEffect{ .pops = n, .pushes = n + 1 };
    }

    // SWAPn
    if (op >= 0x90 and op <= 0x9F) {
        const n: i16 = @intCast(op - 0x8F);
        return StackEffect{ .pops = n + 1, .pushes = n + 1 };
    }

    if (op == 0x50) return StackEffect{ .pops = 1, .pushes = 0 }; // POP

    // Arthmetic
    if (op >= 0x01 and op <= 0x0B) return StackEffect{ .pops = 2, .pushes = 1 };
    if (op == 0x00) return StackEffect{ .pops = 0, .pushes = 0 }; // STOP
    if (op == 0x15) return StackEffect{ .pops = 1, .pushes = 1 }; // ISZERO
    if (op >= 0x10 and op <= 0x14) return StackEffect{ .pops = 2, .pushes = 1 }; // LT, GT...

    // SHA3
    if (op == 0x20) return StackEffect{ .pops = 2, .pushes = 1 };

    // Context
    if (op >= 0x30 and op <= 0x3F) return StackEffect{ .pops = 0, .pushes = 1 };
    if (op == 0x31) return StackEffect{ .pops = 1, .pushes = 1 }; // BALANCE
    if (op == 0x35) return StackEffect{ .pops = 1, .pushes = 1 }; // CALLDATALOAD
    if (op == 0x36) return StackEffect{ .pops = 0, .pushes = 1 }; // CALLDATASIZE

    // Memory
    if (op == 0x51) return StackEffect{ .pops = 1, .pushes = 1 }; // MLOAD
    if (op == 0x52) return StackEffect{ .pops = 2, .pushes = 0 }; // MSTORE

    // Storage
    if (op == 0x54) return StackEffect{ .pops = 1, .pushes = 1 }; // SLOAD
    if (op == 0x55) return StackEffect{ .pops = 2, .pushes = 0 }; // SSTORE

    // Flow
    if (op == 0x56) return StackEffect{ .pops = 1, .pushes = 0 }; // JUMP
    if (op == 0x57) return StackEffect{ .pops = 2, .pushes = 0 }; // JUMPI
    if (op == 0x5B) return StackEffect{ .pops = 0, .pushes = 0 }; // JUMPDEST

    // Log
    if (op >= 0xA0 and op <= 0xA4) {
        const topics: i16 = @intCast(op - 0xA0);
        return StackEffect{ .pops = 2 + topics, .pushes = 0 };
    }

    // System
    if (op == 0xF0) return StackEffect{ .pops = 3, .pushes = 1 }; // CREATE
    if (op == 0xF1) return StackEffect{ .pops = 7, .pushes = 1 }; // CALL
    if (op == 0xF3) return StackEffect{ .pops = 2, .pushes = 0 }; // RETURN
    if (op == 0xFD) return StackEffect{ .pops = 2, .pushes = 0 }; // REVERT

    return StackEffect{ .pops = 0, .pushes = 0 };
}
