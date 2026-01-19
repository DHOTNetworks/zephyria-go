// File: src/parallel_optimized.zig
// Optimized parallel execution infrastructure for the Zig EVM

const std = @import("std");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const HashMap = std.HashMap;
const AutoHashMap = std.AutoHashMap;

const main = @import("main.zig");
const EVM = main.EVM;
const Transaction = main.Transaction;
const BigInt = main.BigInt;

/// Optimized dependency tracking with hash-based access pattern analysis
pub const OptimizedDependencyAnalyzer = struct {
    allocator: Allocator,
    address_access_map: AutoHashMap([20]u8, AccessInfo),
    dependencies: ArrayList(Dependency),

    const AccessInfo = struct {
        readers: ArrayList(u32),
        writers: ArrayList(u32),

        fn init(allocator: Allocator) AccessInfo {
            _ = allocator; // Not used in current implementation
            return AccessInfo{
                .readers = ArrayList(u32){},
                .writers = ArrayList(u32){},
            };
        }

        fn deinit(self: *AccessInfo, allocator: Allocator) void {
            self.readers.deinit(allocator);
            self.writers.deinit(allocator);
        }
    };

    pub fn init(allocator: Allocator) OptimizedDependencyAnalyzer {
        return OptimizedDependencyAnalyzer{
            .allocator = allocator,
            .address_access_map = AutoHashMap([20]u8, AccessInfo).init(allocator),
            .dependencies = ArrayList(Dependency){},
        };
    }

    pub fn deinit(self: *OptimizedDependencyAnalyzer) void {
        var iterator = self.address_access_map.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.address_access_map.deinit();
        self.dependencies.deinit(self.allocator);
    }

    /// Optimized dependency analysis using access lists
    pub fn analyzeDependencies(self: *OptimizedDependencyAnalyzer, transactions: []const Transaction) ![]Dependency {
        self.dependencies.clearRetainingCapacity();
        self.address_access_map.clearRetainingCapacity();

        // 1. Build access patterns from both implicit and explicit access lists
        for (transactions, 0..) |tx, i| {
            const tx_id = @as(u32, @intCast(i));

            // Implicit: 'from' (balance/nonce) and 'to' (balance)
            try self.recordAccess(tx.from, tx_id, .writer);
            if (tx.to) |to_addr| {
                try self.recordAccess(to_addr, tx_id, .writer);
            }

            // Explicit: Access List (EIP-2930)
            for (tx.access_list) |entry| {
                try self.recordAccess(entry.address, tx_id, .writer);
                // Note: In a full implementation, we'd also track storage_keys specifically.
                // For this dependency granularity, marking the whole address as touched is safe.
            }
        }

        // 2. Generate dependencies from Conflicts
        var iterator = self.address_access_map.iterator();
        while (iterator.next()) |entry| {
            const access_info = entry.value_ptr;

            // Conflicts: Write-Write, Read-Write, Write-Read
            // Current model (writer-only for safety) creates a strict ordering
            for (access_info.writers.items, 0..) |tx_a, i| {
                for (access_info.writers.items[i + 1 ..]) |tx_b| {
                    // Ensure deterministic ordering (lower tx_id first)
                    const from = @min(tx_a, tx_b);
                    const to = @max(tx_a, tx_b);
                    try self.dependencies.append(self.allocator, Dependency{
                        .from_tx = from,
                        .to_tx = to,
                        .address = entry.key_ptr.*,
                        .conflict_type = .write_write,
                    });
                }
            }
        }

        return self.dependencies.items;
    }

    fn recordAccess(self: *OptimizedDependencyAnalyzer, address: [20]u8, tx_id: u32, access_type: enum { reader, writer }) !void {
        const result = try self.address_access_map.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = AccessInfo.init(self.allocator);
        }

        switch (access_type) {
            .reader => try result.value_ptr.readers.append(self.allocator, tx_id),
            .writer => try result.value_ptr.writers.append(self.allocator, tx_id),
        }
    }
};

/// Work-stealing thread pool for better load balancing
pub const WorkStealingThreadPool = struct {
    allocator: Allocator,
    threads: []Thread,
    work_queues: []WorkQueue,
    global_queue: WorkQueue,
    shutdown: bool,
    global_mutex: Mutex,
    global_condition: Condition,
    thread_count: u32,

    const WorkQueue = struct {
        items: ArrayList(WorkItem),
        mutex: Mutex,

        fn init(allocator: Allocator) WorkQueue {
            _ = allocator; // Not used in current implementation
            return WorkQueue{
                .items = ArrayList(WorkItem){},
                .mutex = Mutex{},
            };
        }

        fn deinit(self: *WorkQueue, allocator: Allocator) void {
            self.items.deinit(allocator);
        }

        fn push(self: *WorkQueue, allocator: Allocator, item: WorkItem) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.items.append(allocator, item);
        }

        fn pop(self: *WorkQueue) ?WorkItem {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len > 0) {
                return self.items.orderedRemove(0);
            }
            return null;
        }

        fn steal(self: *WorkQueue) ?WorkItem {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len > 1) {
                // Steal from the end (LIFO for stealer, FIFO for owner)
                return self.items.pop();
            }
            return null;
        }
    };

    pub fn init(allocator: Allocator, thread_count: u32) !*WorkStealingThreadPool {
        const pool = try allocator.create(WorkStealingThreadPool);

        // Initialize per-thread work queues
        const work_queues = try allocator.alloc(WorkQueue, thread_count);
        for (work_queues) |*queue| {
            queue.* = WorkQueue.init(allocator);
        }

        pool.* = WorkStealingThreadPool{
            .allocator = allocator,
            .threads = try allocator.alloc(Thread, thread_count),
            .work_queues = work_queues,
            .global_queue = WorkQueue.init(allocator),
            .shutdown = false,
            .global_mutex = Mutex{},
            .global_condition = Condition{},
            .thread_count = thread_count,
        };

        // Start worker threads
        for (pool.threads, 0..) |*thread, i| {
            thread.* = try Thread.spawn(.{}, workerThread, .{ pool, i });
        }

        return pool;
    }

    pub fn deinit(self: *WorkStealingThreadPool) void {
        // Signal shutdown
        self.global_mutex.lock();
        self.shutdown = true;
        self.global_condition.broadcast();
        self.global_mutex.unlock();

        // Wait for all threads to complete
        for (self.threads) |*thread| {
            thread.join();
        }

        // Clean up work queues
        for (self.work_queues) |*queue| {
            queue.deinit(self.allocator);
        }
        self.allocator.free(self.work_queues);
        self.global_queue.deinit(self.allocator);
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    pub fn submitWork(self: *WorkStealingThreadPool, work_item: WorkItem) !void {
        try self.global_queue.push(self.allocator, work_item);

        // Wake up at least one worker to process the work
        self.global_mutex.lock();
        self.global_condition.signal();
        self.global_mutex.unlock();
    }

    fn workerThread(self: *WorkStealingThreadPool, thread_id: usize) void {
        const my_queue = &self.work_queues[thread_id];

        while (true) {
            // 1. Try to get work from own queue
            if (my_queue.pop()) |work_item| {
                var item = work_item;
                item.execute();
                continue;
            }

            // 2. Try to steal work from other threads
            var stolen = false;
            for (self.work_queues, 0..) |*queue, i| {
                if (i == thread_id) continue; // Skip own queue

                if (queue.steal()) |work_item| {
                    var item = work_item;
                    item.execute();
                    stolen = true;
                    break;
                }
            }

            if (stolen) continue;

            // 3. Try global queue
            if (self.global_queue.pop()) |work_item| {
                var item = work_item;
                item.execute();
                continue;
            }

            // 4. Wait for work or shutdown
            self.global_mutex.lock();
            while (self.global_queue.items.items.len == 0 and !self.shutdown) {
                self.global_condition.wait(&self.global_mutex);
            }

            if (self.shutdown) {
                self.global_mutex.unlock();
                break;
            }
            self.global_mutex.unlock();
        }
    }
};

// Speculative execution engine removed per Native_EVM.md (Deterministic focus)

/// Memory pool for reducing allocations
pub const MemoryPool = struct {
    allocator: Allocator,
    small_blocks: ArrayList([]u8),
    medium_blocks: ArrayList([]u8),
    large_blocks: ArrayList([]u8),
    mutex: Mutex,

    const SMALL_SIZE = 256;
    const MEDIUM_SIZE = 4096;
    const LARGE_SIZE = 65536;

    pub fn init(allocator: Allocator) MemoryPool {
        return MemoryPool{
            .allocator = allocator,
            .small_blocks = ArrayList([]u8){},
            .medium_blocks = ArrayList([]u8){},
            .large_blocks = ArrayList([]u8){},
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *MemoryPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.small_blocks.items) |block| {
            self.allocator.free(block);
        }
        for (self.medium_blocks.items) |block| {
            self.allocator.free(block);
        }
        for (self.large_blocks.items) |block| {
            self.allocator.free(block);
        }

        self.small_blocks.deinit(self.allocator);
        self.medium_blocks.deinit(self.allocator);
        self.large_blocks.deinit(self.allocator);
    }

    pub fn acquire(self: *MemoryPool, size: usize) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (size <= SMALL_SIZE) {
            if (self.small_blocks.items.len > 0) {
                const block = self.small_blocks.pop();
                return block[0..@min(size, block.len)];
            }
            return try self.allocator.alloc(u8, @max(size, SMALL_SIZE));
        } else if (size <= MEDIUM_SIZE) {
            if (self.medium_blocks.items.len > 0) {
                const block = self.medium_blocks.pop();
                return block[0..@min(size, block.len)];
            }
            return try self.allocator.alloc(u8, @max(size, MEDIUM_SIZE));
        } else if (size <= LARGE_SIZE) {
            if (self.large_blocks.items.len > 0) {
                const block = self.large_blocks.pop();
                return block[0..@min(size, block.len)];
            }
            return try self.allocator.alloc(u8, @max(size, LARGE_SIZE));
        } else {
            // For very large allocations, use direct allocation
            return try self.allocator.alloc(u8, size);
        }
    }

    pub fn release(self: *MemoryPool, block: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const size = block.len;
        if (size == SMALL_SIZE) {
            self.small_blocks.append(self.allocator, block) catch {
                self.allocator.free(block);
            };
        } else if (size == MEDIUM_SIZE) {
            self.medium_blocks.append(self.allocator, block) catch {
                self.allocator.free(block);
            };
        } else if (size == LARGE_SIZE) {
            self.large_blocks.append(self.allocator, block) catch {
                self.allocator.free(block);
            };
        } else {
            // Direct allocated blocks are freed directly
            self.allocator.free(block);
        }
    }
};

/// Re-export optimized types
pub const Dependency = @import("parallel.zig").Dependency;
pub const ConflictType = @import("parallel.zig").ConflictType;
pub const ExecutionResult = @import("parallel.zig").ExecutionResult;
pub const StateChange = @import("parallel.zig").StateChange;
pub const ChangeType = @import("parallel.zig").ChangeType;
pub const WorkItem = @import("parallel.zig").WorkItem;
pub const ParallelExecutionStats = @import("parallel.zig").ParallelExecutionStats;
pub const ConflictDetectionLevel = @import("parallel.zig").ConflictDetectionLevel;

pub const ParallelConfig = struct {
    max_threads: u32 = 4,
    batch_size: u32 = 100,
    dependency_lookahead: u32 = 50, // How many transactions ahead to analyze for dependencies
    enable_state_snapshots: bool = true,
    conflict_detection_level: ConflictDetectionLevel = .medium,
};
pub const OptimizedParallelScheduler = struct {
    allocator: Allocator,
    thread_pool: *WorkStealingThreadPool,
    dependency_analyzer: OptimizedDependencyAnalyzer,
    memory_pool: MemoryPool,
    execution_results: ArrayList(ExecutionResult),
    pending_transactions: ArrayList(Transaction),
    completed_mask: []bool,
    dependency_count: []u32,
    config: ParallelConfig,

    // Atomic counter for wave tracking
    completed_in_wave: std.atomic.Value(u32),

    pub fn init(allocator: Allocator, config: ParallelConfig) !*OptimizedParallelScheduler {
        const scheduler = try allocator.create(OptimizedParallelScheduler);
        scheduler.* = OptimizedParallelScheduler{
            .allocator = allocator,
            .thread_pool = try WorkStealingThreadPool.init(allocator, config.max_threads),
            .dependency_analyzer = OptimizedDependencyAnalyzer.init(allocator),
            .memory_pool = MemoryPool.init(allocator),
            .execution_results = ArrayList(ExecutionResult){},
            .pending_transactions = ArrayList(Transaction){},
            .completed_mask = &[_]bool{},
            .dependency_count = &[_]u32{},
            .config = config,
            .completed_in_wave = std.atomic.Value(u32).init(0),
        };
        return scheduler;
    }

    pub fn deinit(self: *OptimizedParallelScheduler) void {
        self.thread_pool.deinit();
        self.dependency_analyzer.deinit();
        self.memory_pool.deinit();

        for (self.execution_results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.execution_results.deinit(self.allocator);
        self.pending_transactions.deinit(self.allocator);

        if (self.completed_mask.len > 0) {
            self.allocator.free(self.completed_mask);
        }
        if (self.dependency_count.len > 0) {
            self.allocator.free(self.dependency_count);
        }

        self.allocator.destroy(self);
    }

    /// Execute transactions with optimized parallel processing
    pub fn executeTransactionBatch(self: *OptimizedParallelScheduler, transactions: []const Transaction) ![]ExecutionResult {
        const start_time = std.time.nanoTimestamp();

        // Setup
        try self.setupExecution(transactions);

        // Optimized dependency analysis
        const dependencies = try self.dependency_analyzer.analyzeDependencies(transactions);

        // Build dependency graph
        self.buildDependencyGraph(dependencies);

        // Execute with wave-based deterministic strategy
        try self.executeWithOptimizations(transactions, dependencies);

        const end_time = std.time.nanoTimestamp();
        const execution_time = end_time - start_time;

        std.log.info("Wave-based execution completed in {d}ms", .{@as(f64, @floatFromInt(execution_time)) / 1_000_000.0});

        return self.execution_results.items;
    }

    fn setupExecution(self: *OptimizedParallelScheduler, transactions: []const Transaction) !void {
        self.pending_transactions.clearRetainingCapacity();

        // Resize tracking arrays
        if (self.completed_mask.len < transactions.len) {
            if (self.completed_mask.len > 0) self.allocator.free(self.completed_mask);
            self.completed_mask = try self.allocator.alloc(bool, transactions.len);
        }
        if (self.dependency_count.len < transactions.len) {
            if (self.dependency_count.len > 0) self.allocator.free(self.dependency_count);
            self.dependency_count = try self.allocator.alloc(u32, transactions.len);
        }

        // Initialize execution results list with correct size
        for (self.execution_results.items) |*res| res.deinit(self.allocator);
        self.execution_results.clearRetainingCapacity();
        try self.execution_results.resize(self.allocator, transactions.len);

        @memset(self.completed_mask[0..transactions.len], false);
        @memset(self.dependency_count[0..transactions.len], 0);

        for (transactions) |tx| {
            try self.pending_transactions.append(self.allocator, tx);
        }
    }

    fn buildDependencyGraph(self: *OptimizedParallelScheduler, dependencies: []const Dependency) void {
        for (dependencies) |dep| {
            self.dependency_count[dep.to_tx] += 1;
        }
    }

    /// Execute with deterministic Wave-based strategy
    fn executeWithOptimizations(self: *OptimizedParallelScheduler, transactions: []const Transaction, dependencies: []const Dependency) !void {
        var completed_total: u32 = 0;
        const total_txs = @as(u32, @intCast(transactions.len));

        while (completed_total < total_txs) {
            // 1. Identify "Ready" transactions (in-degree 0)
            var wave_list = ArrayList(u32){};
            defer wave_list.deinit(self.allocator);

            for (0..total_txs) |i| {
                const tx_id = @as(u32, @intCast(i));
                if (!self.completed_mask[tx_id] and self.dependency_count[tx_id] == 0) {
                    try wave_list.append(self.allocator, tx_id);
                }
            }

            if (wave_list.items.len == 0) {
                if (completed_total < total_txs) return error.CircularDependencyDetected;
                break;
            }

            // 2. Dispatch Wave to thread pool
            const wave_size = @as(u32, @intCast(wave_list.items.len));
            self.completed_in_wave.store(0, .monotonic);

            for (wave_list.items) |tx_id| {
                try self.submitOptimizedExecution(tx_id);
            }

            // 3. Wait for Wave Barrier
            while (self.completed_in_wave.load(.acquire) < wave_size) {
                std.Thread.yield() catch {}; // Allow other threads to run
                std.Thread.sleep(10 * std.time.ns_per_us); // 10us sleep to prevent CPU saturation
            }

            // 4. Resolve dependencies for the next wave
            for (wave_list.items) |idx| {
                for (dependencies) |dep| {
                    if (dep.from_tx == idx) {
                        self.dependency_count[dep.to_tx] -= 1;
                    }
                }
                completed_total += 1;
            }
        }
    }

    fn submitOptimizedExecution(self: *OptimizedParallelScheduler, tx_id: u32) !void {
        const context = try self.allocator.create(OptimizedExecutionContext);
        context.* = OptimizedExecutionContext{
            .scheduler = self,
            .tx_id = tx_id,
            .transaction = self.pending_transactions.items[tx_id],
        };

        const work_item = WorkItem{
            .execute_fn = executeOptimizedTransactionWork,
            .context = context,
        };

        try self.thread_pool.submitWork(work_item);
    }
};

const OptimizedExecutionContext = struct {
    scheduler: *OptimizedParallelScheduler,
    tx_id: u32,
    transaction: Transaction,
};

fn executeOptimizedTransactionWork(work_item: *WorkItem) void {
    const context: *OptimizedExecutionContext = @ptrCast(@alignCast(work_item.context));

    // Ensure we ALWAYS signal the scheduler and clean up, even on early exit
    defer {
        _ = context.scheduler.completed_in_wave.fetchAdd(1, .release);
        context.scheduler.allocator.destroy(context);
    }

    // In a production JIT, each thread would have a pre-warmed EVM instance.
    // Here we init for correctness, ensuring JIT is engaged.
    var evm = EVM.init(context.scheduler.allocator) catch {
        std.log.err("Worker {d}: Failed to initialize EVM", .{context.tx_id});
        return;
    };
    defer evm.deinit();

    var result = ExecutionResult{
        .tx_id = context.tx_id,
        .success = false,
        .gas_used = 0,
        .error_msg = null,
        .state_changes = ArrayList(StateChange){},
    };

    // Execute transaction using JIT
    evm.applyTransaction(context.transaction) catch |err| {
        result.error_msg = context.scheduler.allocator.dupe(u8, @errorName(err)) catch null;
    };

    if (result.error_msg == null) {
        result.success = true;
        result.gas_used = evm.gas_used;
    }

    // Store result
    context.scheduler.execution_results.items[context.tx_id] = result;
    context.scheduler.completed_mask[context.tx_id] = true;
}

// Performance testing functions
pub fn benchmarkOptimizedExecution(allocator: Allocator) !void {
    std.debug.print("=== Optimized Parallel Execution Benchmark ===\n", .{});

    const configs = [_]ParallelConfig{
        .{ .max_threads = 1 },
        .{ .max_threads = 2 },
        .{ .max_threads = 4 },
        .{ .max_threads = 8 },
    };

    const transaction_counts = [_]u32{ 100, 500, 1000 };

    for (transaction_counts) |tx_count| {
        std.debug.print("\nTransaction count: {d}\n", .{tx_count});

        for (configs) |config| {
            var scheduler = try OptimizedParallelScheduler.init(allocator, config);
            defer scheduler.deinit();

            // Generate test transactions
            const transactions = try generateTestTransactions(allocator, tx_count);
            defer allocator.free(transactions);

            const start_time = std.time.nanoTimestamp();
            const results = try scheduler.executeTransactionBatch(transactions);
            const end_time = std.time.nanoTimestamp();

            const execution_time = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
            const throughput = @as(f64, @floatFromInt(tx_count)) / (execution_time / 1000.0);

            var successful: u32 = 0;
            for (results) |result| {
                if (result.success) successful += 1;
            }

            std.debug.print("  {d} threads: {d:.2}ms ({d:.0} tx/s)\n", .{ config.max_threads, execution_time, throughput });
        }
    }
}

fn generateTestTransactions(allocator: Allocator, count: u32) ![]Transaction {
    const transactions = try allocator.alloc(Transaction, count);

    for (transactions, 0..) |*tx, i| {
        var from_addr: [20]u8 = undefined;
        var to_addr: [20]u8 = undefined;
        @memset(&from_addr, 0);
        @memset(&to_addr, 0);

        // Create some address patterns for realistic dependency testing
        from_addr[19] = @intCast((i % 50) + 1);
        to_addr[19] = @intCast(((i + 25) % 50) + 1);

        tx.* = Transaction{
            .from = from_addr,
            .to = to_addr,
            .value = BigInt.init(100 + i),
            .data = &[_]u8{},
            .gas_limit = 21000,
            .gas_price = BigInt.init(20000000000),
        };
    }

    return transactions;
}
test "Deterministic Parallel JIT Execution" {
    const allocator = std.testing.allocator;

    const config = ParallelConfig{
        .max_threads = 4,
    };

    var scheduler = try OptimizedParallelScheduler.init(allocator, config);
    defer scheduler.deinit();

    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;
    const addr3 = [_]u8{3} ** 20;

    const transactions = [_]Transaction{
        .{
            .from = addr1,
            .to = addr2,
            .value = BigInt.init(100),
            .data = &[_]u8{},
            .gas_limit = 21000,
            .gas_price = BigInt.init(1),
        },
        .{
            .from = addr2,
            .to = addr3,
            .value = BigInt.init(50),
            .data = &[_]u8{},
            .gas_limit = 21000,
            .gas_price = BigInt.init(1),
        },
    };

    const results = try scheduler.executeTransactionBatch(&transactions);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}
