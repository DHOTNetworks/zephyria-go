const std = @import("std");
const types = @import("core").types;
const consensus = @import("consensus");
const zelius = @import("consensus").zelius;
const vrf = @import("consensus").vrf;
const vdf = @import("consensus").vdf;
const blockchain = @import("core").blockchain;
const tx_pool = @import("core").tx_pool;
const executor = @import("core").executor;
const state = @import("core").state;
const p2p = @import("p2p");

pub const Miner = struct {
    allocator: std.mem.Allocator,
    chain: *blockchain.Blockchain,
    tx_pool: *tx_pool.TxPool,
    engine: *zelius.ZeliusEngine,
    executor: *executor.Executor,
    state: *state.State,

    running: *std.atomic.Value(bool),
    validator_addr: types.Address,
    p2p_server: ?*p2p.Server,

    pub fn init(
        allocator: std.mem.Allocator,
        chain: *blockchain.Blockchain,
        pool: *tx_pool.TxPool,
        engine: *zelius.ZeliusEngine,
        exec: *executor.Executor,
        state_obj: *state.State,
        addr: types.Address,
        running_flag: *std.atomic.Value(bool),
    ) !*Miner {
        const self = try allocator.create(Miner);
        self.* = Miner{
            .allocator = allocator,
            .chain = chain,
            .tx_pool = pool,
            .engine = engine,
            .executor = exec,
            .running = running_flag,
            .validator_addr = addr,
            .state = state_obj,
            .p2p_server = null,
        };
        return self;
    }

    pub fn deinit(self: *Miner) void {
        self.allocator.destroy(self);
    }

    pub fn set_p2p(self: *Miner, server: *p2p.Server) void {
        self.p2p_server = server;
    }

    pub fn start(self: *Miner) !void {
        std.debug.print("[Miner] Starting block production loop for {f}\n", .{self.validator_addr});

        while (self.running.load(.seq_cst)) {
            // 1. Get current head
            const parent = self.chain.current_block orelse return error.NoGenesis;
            const next_number = parent.header.number + 1;

            // 2. Check VRF Eligibility
            const eligible = try self.check_eligibility(parent);
            if (!eligible) {
                // Wait for next slot
                std.Thread.sleep(1000 * std.time.ns_per_ms);
                continue;
            }

            std.debug.print("[Miner] Eligible for block {d}, starting production...\n", .{next_number});

            // 3. Produce Block
            const block = try self.produce_block(parent);

            // 4. Seal Block (VDF + Signature)
            try self.engine.seal(block);

            // 5. Add to Chain
            try self.chain.add_block(block);

            std.debug.print("[Miner] Mined block {d}! Hash: {f}\n", .{ next_number, block.hash() });

            // Wait for next slot
            std.Thread.sleep(1000 * std.time.ns_per_ms);
        }
    }

    fn check_eligibility(self: *Miner, parent: *types.Block) !bool {
        _ = self;
        _ = parent;
        return true; // Stub: everyone mines
    }

    fn produce_block(self: *Miner, parent: *types.Block) !*types.Block {
        const next_number = parent.header.number + 1;
        const timestamp = @as(u64, @intCast(std.time.timestamp()));

        // 1. Fetch Txs from pool
        const txs = self.tx_pool.get_transactions(100); // returns []types.Transaction

        // 2. Construct Header
        const header = types.Header{
            .parent_hash = parent.hash(),
            .number = next_number,
            .time = timestamp,
            .verkle_root = parent.header.verkle_root, // Initial value
            .tx_hash = types.Hash.zero(),
            .coinbase = self.validator_addr,
            .extra_data = &[_]u8{},
            .gas_limit = parent.header.gas_limit,
            .gas_used = 0,
            .base_fee = parent.header.base_fee,
        };

        const block = try self.allocator.create(types.Block);
        block.* = types.Block{
            .header = header,
            .transactions = txs,
        };

        // 3. Execute Block (Updates Verkle Root)

        // Create slice of pointers for Executor interface
        var tx_ptrs = try self.allocator.alloc(*types.Transaction, txs.len);
        defer self.allocator.free(tx_ptrs);
        for (block.transactions, 0..) |*tx, i| {
            tx_ptrs[i] = tx;
        }

        const root = try self.executor.apply_block(self.state, &block.header, tx_ptrs);
        block.header.verkle_root = root; // Assign the returned Hash directly

        // Broadcast to P2P network
        if (self.p2p_server) |server| {
            const msg = p2p.types.NewBlockMsg{
                .block = block.*,
                .total_difficulty = 1, // Stub
                .hop_count = 0,
            };
            server.broadcast(p2p.types.MsgNewBlock, msg) catch |err| {
                std.debug.print("[Miner] Failed to broadcast block: {}\n", .{err});
            };
        }

        self.chain.set_head(block);

        // Remove executed transactions from pool
        self.tx_pool.remove_executed(txs);

        return block;
    }
};
