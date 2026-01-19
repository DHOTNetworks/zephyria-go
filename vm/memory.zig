const std = @import("std");

// EVM Memory implementation using std.mem.Allocator
// Replaced fixed mmap with dynamic realloc to avoid OS-specific paging/safety issues on macOS/ARM64.
pub const Memory = struct {
    raw_ptr: [*]u8, // Unsafe pointer for JIT interaction (synced with data.ptr)
    data: []u8, // Managed slice

    const MAX_MEMORY = 1 * 1024 * 1024 * 1024; // 1GB limit

    pub fn init(allocator: std.mem.Allocator) !Memory {
        // Initial allocation (can be 0 or small)
        const slice = try allocator.alloc(u8, 0);
        return Memory{
            .raw_ptr = slice.ptr,
            .data = slice,
        };
    }

    pub fn deinit(self: *Memory, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn resize(self: *Memory, allocator: std.mem.Allocator, new_size: usize) !void {
        if (new_size > MAX_MEMORY) return error.OutOfMemory;
        if (new_size <= self.data.len) return; // Do not shrink

        const old_len = self.data.len;
        // Resize memory to accommodate new_size

        // Align expansion to 32 bytes (EVM word) or page size?
        // EVM expands by word, but costs per word.
        // Let's alloc exact size requested for now to catch OOB, or algin to 32 bytes.
        // ensureCapacity usually passes exact needed.
        // Let's stick to requested size or slightly rounded up if preferred, but exact is fine.

        // Improve allocator performance by aligning to block size?
        // Let's align to 1024 bytes to reduce realloc churn.
        const alloc_size = new_size;
        // alloc_size = (new_size + 1023) & ~@as(usize, 1023); // Align 1KB
        // Actually, EVM tests relied on exact bounds? No, memory size is just capacity.
        // EVM MSIZE opcode returns current size.
        // If we alloc more, MSIZE might report usage based on `size` tracked elsewhere?
        // No, EVM spec says memory size expands.
        // Typically expansion is calculated by GAS logic (in main.zig `consumeGas`).
        // Memory.zig just holds the buffer.
        // If Logic asks for 100 bytes, we provide 100.

        self.data = try allocator.realloc(self.data, alloc_size);
        self.raw_ptr = self.data.ptr;

        // Zero-fill new memory (EVM requirement)
        @memset(self.data[old_len..], 0);
    }

    pub fn store(self: *Memory, allocator: std.mem.Allocator, offset: usize, value: []const u8) !void {
        const required_size = offset + value.len;
        if (required_size > self.data.len) {
            try self.resize(allocator, required_size);
        }
        @memcpy(self.data[offset .. offset + value.len], value);
    }

    pub fn load(self: *Memory, allocator: std.mem.Allocator, offset: usize, len: usize) ![]const u8 {
        const required_size = offset + len;
        if (required_size > self.data.len) {
            try self.resize(allocator, required_size);
        }
        return self.data[offset .. offset + len];
    }

    pub fn ensureCapacity(self: *Memory, allocator: std.mem.Allocator, min_size: usize) !void {
        if (min_size > self.data.len) {
            try self.resize(allocator, min_size);
        }
    }

    // Compat helpers
    pub fn loadWord(self: *Memory, allocator: std.mem.Allocator, offset: usize) ![]const u8 {
        return self.load(allocator, offset, 32);
    }

    pub fn storeByte(self: *Memory, allocator: std.mem.Allocator, offset: usize, value: u8) !void {
        const required_size = offset + 1;
        if (required_size > self.data.len) {
            try self.resize(allocator, required_size);
        }
        self.data[offset] = value;
    }

    pub fn loadByte(self: *Memory, offset: usize) u8 {
        if (offset >= self.data.len) return 0;
        return self.data[offset];
    }

    // For JIT Context
    pub fn getData(self: *Memory) []u8 {
        return self.data;
    }

    pub fn size(self: *Memory) usize {
        return self.data.len;
    }
};
