const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// IO Operation Type
pub const OpType = enum {
    Read,
    Write,
    FSync,
};

/// IO Operation Request
pub const IoOp = struct {
    op_type: OpType,
    file: std.fs.File,
    buffer: []u8,
    offset: u64,
    user_data: usize, // Callback context or ID

    // Result fields (filled on completion)
    result_len: usize = 0,
    result_error: ?anyerror = null,

    // Cleanup behavior
    allocator: ?std.mem.Allocator = null,
    owns_buffer: bool = false,
};

/// Completion Callback
pub const CompletionCallback = *const fn (context: *anyopaque, op: *IoOp) void;

/// IO Engine Interface
pub const IoEngine = struct {
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        submit: *const fn (ctx: *anyopaque, op: *IoOp) anyerror!void,
        tick: *const fn (ctx: *anyopaque) anyerror!usize, // Process completions
    };

    pub fn deinit(self: IoEngine) void {
        self.vtable.deinit(self.impl);
    }

    pub fn submit(self: IoEngine, op: *IoOp) anyerror!void {
        return self.vtable.submit(self.impl, op);
    }

    /// Poll for completions. Returns number of completed ops.
    pub fn tick(self: IoEngine) anyerror!usize {
        return self.vtable.tick(self.impl);
    }
};

/// Thread-safe completion queue
const CompletedQueue = struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayListUnmanaged(*IoOp),

    fn init() CompletedQueue {
        return .{
            .mutex = .{},
            .list = .{},
        };
    }

    fn deinit(self: *CompletedQueue, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    fn put(self: *CompletedQueue, allocator: std.mem.Allocator, op: *IoOp) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.list.append(allocator, op);
    }

    fn get(self: *CompletedQueue) ?*IoOp {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.list.items.len == 0) return null;
        return self.list.pop();
    }
};

/// ThreadPool Implementation (Fallback for non-Linux)
pub const ThreadPoolEngine = struct {
    allocator: Allocator,
    pool: std.Thread.Pool,
    completed_queue: CompletedQueue,

    // We need a wrapper to match the generic interface
    pub fn init(allocator: Allocator) !IoEngine {
        const self = try allocator.create(ThreadPoolEngine);
        self.allocator = allocator;
        try self.pool.init(.{ .allocator = allocator });
        self.completed_queue = CompletedQueue.init();

        return IoEngine{
            .impl = self,
            .vtable = &VTable,
        };
    }

    const VTable = IoEngine.VTable{
        .deinit = deinit,
        .submit = submit,
        .tick = tick,
    };

    fn deinit(ctx: *anyopaque) void {
        const self: *ThreadPoolEngine = @ptrCast(@alignCast(ctx));
        self.pool.deinit();

        // Drain pending ops
        while (self.completed_queue.get()) |op| {
            if (op.allocator) |alloc| {
                if (op.owns_buffer) alloc.free(op.buffer);
                alloc.destroy(op);
            }
        }

        self.completed_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn submit(ctx: *anyopaque, op: *IoOp) anyerror!void {
        const self: *ThreadPoolEngine = @ptrCast(@alignCast(ctx));
        try self.pool.spawn(worker, .{ self, op });
    }

    fn worker(self: *ThreadPoolEngine, op: *IoOp) void {
        // Perform blocking I/O
        switch (op.op_type) {
            .Read => {
                const n = op.file.preadAll(op.buffer, op.offset) catch |err| {
                    op.result_error = err;
                    return;
                };
                op.result_len = n;
            },
            .Write => {
                op.file.pwriteAll(op.buffer, op.offset) catch |err| {
                    op.result_error = err;
                };
                op.result_len = op.buffer.len; // Assume full write if no error for simplicity
            },
            .FSync => {
                op.file.sync() catch |err| {
                    op.result_error = err;
                };
            },
        }

        // Push to completion queue
        self.completed_queue.put(self.allocator, op) catch return;
    }

    fn tick(ctx: *anyopaque) anyerror!usize {
        const self: *ThreadPoolEngine = @ptrCast(@alignCast(ctx));
        var count: usize = 0;
        while (self.completed_queue.get()) |op| {
            count += 1;
            if (op.allocator) |alloc| {
                if (op.owns_buffer) alloc.free(op.buffer);
                alloc.destroy(op);
            }
        }
        return count;
    }
};

/// Factory
pub fn create(allocator: Allocator) !IoEngine {
    if (builtin.os.tag == .linux) {
        // TODO: Implement IoUringEngine
        return ThreadPoolEngine.init(allocator);
    } else {
        return ThreadPoolEngine.init(allocator);
    }
}
