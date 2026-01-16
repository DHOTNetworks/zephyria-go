const std = @import("std");
const core = @import("core");
const p2p = @import("p2p");
const types = core.types;
const encoding = @import("encoding");
const rlp = encoding.rlp;

pub const RpcHandler = struct {
    allocator: std.mem.Allocator,
    chain: *core.blockchain.Blockchain,
    pool: *core.tx_pool.TxPool,
    exec: *core.executor.Executor,
    state: *core.state.State,
    p2p: ?*p2p.Server,

    pub fn init(
        allocator: std.mem.Allocator,
        chain: *core.blockchain.Blockchain,
        pool: *core.tx_pool.TxPool,
        exec: *core.executor.Executor,
        state: *core.state.State,
    ) RpcHandler {
        return .{
            .allocator = allocator,
            .chain = chain,
            .pool = pool,
            .exec = exec,
            .state = state,
            .p2p = null,
        };
    }

    pub fn set_p2p(self: *RpcHandler, p2p_server: *p2p.Server) void {
        self.p2p = p2p_server;
    }

    pub fn handle_request(self: *RpcHandler, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!std.json.Value {
        if (std.mem.eql(u8, method, "eth_chainId")) {
            return self.eth_chainId(allocator);
        } else if (std.mem.eql(u8, method, "eth_blockNumber")) {
            return self.eth_blockNumber(allocator);
        } else if (std.mem.eql(u8, method, "net_version")) {
            return self.net_version(allocator);
        } else if (std.mem.eql(u8, method, "web3_clientVersion")) {
            return self.web3_clientVersion();
        } else if (std.mem.eql(u8, method, "eth_getBalance")) {
            return self.eth_getBalance(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_sendRawTransaction")) {
            return self.eth_sendRawTransaction(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_getTransactionCount")) {
            return self.eth_getTransactionCount(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_getBlockByNumber")) {
            return self.eth_getBlockByNumber(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_estimateGas")) {
            return self.eth_estimateGas(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_gasPrice")) {
            return self.eth_gasPrice(allocator);
        } else if (std.mem.eql(u8, method, "eth_maxPriorityFeePerGas")) {
            return self.eth_maxPriorityFeePerGas(allocator);
        } else if (std.mem.eql(u8, method, "eth_feeHistory")) {
            return self.eth_feeHistory(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_call")) {
            return self.eth_call(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_getCode")) {
            return self.eth_getCode(allocator, params);
        } else if (std.mem.eql(u8, method, "net_listening")) {
            return self.net_listening(allocator);
        } else if (std.mem.eql(u8, method, "net_peerCount")) {
            return self.net_peerCount(allocator);
        } else if (std.mem.eql(u8, method, "eth_getTransactionReceipt")) {
            return self.eth_getTransactionReceipt(allocator, params);
        } else if (std.mem.eql(u8, method, "eth_getBlockByHash")) {
            return self.eth_getBlockByHash(allocator, params);
        }

        return error.MethodNotFound;
    }

    // Methods

    fn eth_chainId(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        var buf: [32]u8 = undefined;
        const str = try @import("utils").hex.toHexBuffer(&buf, self.chain.chain_id);
        return std.json.Value{ .string = try allocator.dupe(u8, str) };
    }

    fn eth_gasPrice(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        _ = self;
        _ = allocator;
        // Return 20 Gwei (matches Go default)
        return std.json.Value{ .string = "0x4a817c800" };
    }

    fn eth_maxPriorityFeePerGas(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        _ = self;
        _ = allocator;
        // Return 2 Gwei (matches Go default)
        return std.json.Value{ .string = "0x77359400" };
    }

    fn eth_feeHistory(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        _ = self;
        var count: usize = 1;
        if (params == .array and params.array.items.len > 0) {
            const v = params.array.items[0];
            if (v == .integer) {
                count = @as(usize, @intCast(v.integer));
            } else if (v == .string) {
                count = try std.fmt.parseInt(usize, std.mem.trimLeft(u8, v.string, "0x"), 16);
            }
        }

        if (count > 1024) count = 1024;

        // Count percentiles
        var percentile_count: usize = 0;
        if (params.array.items.len > 2 and params.array.items[2] == .array) {
            percentile_count = params.array.items[2].array.items.len;
        }

        var map = std.json.ObjectMap.init(allocator);
        // Minimal valid fee history
        try map.put("oldestBlock", std.json.Value{ .string = "0x1" });

        var baseFees = std.json.Array.init(allocator);
        var gasRatios = std.json.Array.init(allocator);
        var rewards = std.json.Array.init(allocator);

        // Fill arrays
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try baseFees.append(std.json.Value{ .string = "0x430e23400" });
            try gasRatios.append(std.json.Value{ .float = 0.0 });

            var block_rewards = std.json.Array.init(allocator);
            var j: usize = 0;
            while (j < percentile_count) : (j += 1) {
                // Return 2 Gwei (0x77359400) for every requested percentile
                try block_rewards.append(std.json.Value{ .string = "0x77359400" });
            }
            try rewards.append(std.json.Value{ .array = block_rewards });
        }
        // baseFee needs count + 1 items
        try baseFees.append(std.json.Value{ .string = "0x430e23400" });

        try map.put("baseFeePerGas", std.json.Value{ .array = baseFees });
        try map.put("gasUsedRatio", std.json.Value{ .array = gasRatios });
        try map.put("reward", std.json.Value{ .array = rewards });
        return std.json.Value{ .object = map };
    }

    fn eth_estimateGas(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        _ = self;
        _ = allocator;
        _ = params;
        // Return 1,000,000 (enough for contracts)
        return std.json.Value{ .string = "0xf4240" };
    }

    fn eth_call(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        _ = self;
        _ = allocator;
        // params: [tx_object, block_tag]
        if (params == .array and params.array.items.len > 0) {
            // Check params if needed
        }

        // Stub: Return empty bytes for EOA
        return std.json.Value{ .string = "0x" };
    }

    fn eth_getCode(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        _ = self;
        _ = allocator;
        _ = params;
        // Stub: Return empty bytes (EOA)
        return std.json.Value{ .string = "0x" };
    }

    fn net_listening(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        _ = self;
        _ = allocator;
        return std.json.Value{ .bool = true };
    }

    fn net_peerCount(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        var count: usize = 0;
        if (self.p2p) |p| {
            p.lock.lock();
            defer p.lock.unlock();
            count = p.peers.items.len;
        }
        var b: [32]u8 = undefined;
        const out = try @import("utils").hex.toHexBuffer(&b, count);
        return std.json.Value{ .string = try allocator.dupe(u8, out) };
    }

    fn eth_blockNumber(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        const head = self.chain.get_head();
        var b: [32]u8 = undefined;
        const out = try @import("utils").hex.toHexBuffer(&b, head.?.header.number);
        return std.json.Value{ .string = try allocator.dupe(u8, out) };
    }

    fn net_version(self: *RpcHandler, allocator: std.mem.Allocator) !std.json.Value {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{self.chain.chain_id});
        return std.json.Value{ .string = try allocator.dupe(u8, str) };
    }

    fn web3_clientVersion(self: *RpcHandler) !std.json.Value {
        _ = self;
        return std.json.Value{ .string = "Zephyria/v0.1.0/zig-edition" };
    }

    fn eth_getBalance(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        // params: [address, blockTag]
        if (params != .array or params.array.items.len < 1) return error.InvalidParams;

        const addr_str = params.array.items[0].string;
        var address: types.Address = undefined;
        _ = try std.fmt.hexToBytes(&address.bytes, std.mem.trimLeft(u8, addr_str, "0x"));

        const balance = self.state.get_balance(address);

        // Turn u256 into hex string
        var b = std.mem.nativeToBig(u256, balance);
        return std.json.Value{ .string = try @import("utils").hex.encode(allocator, std.mem.asBytes(&b)) };
    }

    fn eth_getTransactionCount(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        if (params != .array or params.array.items.len < 1) return error.InvalidParams;
        // Return 0 nonce for now - technically should check state.get_nonce(addr)
        // Let's improve it while we are here.
        const addr_str = params.array.items[0].string;
        var address: types.Address = undefined;
        _ = try std.fmt.hexToBytes(&address.bytes, std.mem.trimLeft(u8, addr_str, "0x"));

        const nonce = self.state.get_nonce(address);
        var n = std.mem.nativeToBig(u64, nonce);
        return std.json.Value{ .string = try @import("utils").hex.encode(allocator, std.mem.asBytes(&n)) };
    }

    fn eth_sendRawTransaction(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        if (params != .array or params.array.items.len < 1) return error.InvalidParams;

        const raw_tx_hex = params.array.items[0].string;
        const raw_tx_bytes = try allocator.alloc(u8, raw_tx_hex.len / 2); // approximate if 0x
        // We don't need defer free if it's in arena, but let's be consistent or just use arena
        // Actually allocator here is the request arena.

        const actual_bytes = try std.fmt.hexToBytes(raw_tx_bytes, std.mem.trimLeft(u8, raw_tx_hex, "0x"));

        // Decode RLP transaction (this handles the missing 'from' field)
        const tx_decode = @import("core").tx_decode;
        const tx = try tx_decode.decodeTransaction(allocator, actual_bytes);

        // We need a pointer to heap allocated tx to add to pool (ref pool.zig logic)
        // TxPool uses the global allocator (self.allocator) for persistent storage.
        const heap_tx = try self.allocator.create(types.Transaction);
        heap_tx.* = tx;
        // Copy data slice to persistent storage
        heap_tx.data = try self.allocator.dupe(u8, tx.data);

        // Add to Pool
        const added = try self.pool.add(heap_tx);
        if (!added) {
            heap_tx.deinit(self.allocator);
            self.allocator.destroy(heap_tx);
        }

        // Return Hash
        var hash_out: [32]u8 = undefined;
        const hash = tx.hash();
        @memcpy(&hash_out, &hash.bytes);
        return std.json.Value{ .string = try @import("utils").hex.encode(allocator, &hash_out) };
    }

    fn formatBlock(self: *RpcHandler, allocator: std.mem.Allocator, block: *types.Block, full_tx: bool) !std.json.Value {
        _ = self;
        var map = std.json.ObjectMap.init(allocator);
        const hex = @import("utils").hex;

        var buf: [66]u8 = undefined;

        // Number

        var b_n = std.mem.nativeToBig(u64, block.header.number);
        try map.put("number", std.json.Value{ .string = try hex.encode(allocator, std.mem.trimLeft(u8, std.mem.asBytes(&b_n), &[_]u8{0})) });

        // Hash (mocked if not stored in block struct, but we have verkle/tx_hash)
        // Ideally block struct should have its own hash, or we compute it.
        // For now, let's use verkle root as placeholder or compute properly if we had the function exposed.
        // Actually, the caller usually has the hash. But formatBlock takes just block.
        // Let's rely on header.hash() if available, else omit or compute.
        // Checking types.zig... Header doesn't have hash() method visible here easily without import.
        // Let's skip expensive computation or use zero for now as it wasn't requested explicitly in params.
        // BUT MetaMask needs it. Let's computed it.
        // Wait, I can't easily compute it here without properly RLP encoding header.
        // Let's just put the mixHash or something safe.

        // Compute Hash
        var h_res: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
        const encoded = try block.header.rlp_encode(allocator);
        defer allocator.free(encoded);
        hasher.update(encoded);
        hasher.final(&h_res);

        try map.put("hash", std.json.Value{ .string = try hex.encodeBuffer(&buf, &h_res) });
        try map.put("parentHash", std.json.Value{ .string = try hex.encodeBuffer(&buf, &block.header.parent_hash.bytes) });
        try map.put("stateRoot", std.json.Value{ .string = try hex.encodeBuffer(&buf, &block.header.verkle_root.bytes) });

        // Transactions
        var txs = std.json.Array.init(allocator);
        for (block.transactions, 0..) |tx, i| {
            if (full_tx) {
                var tx_map = std.json.ObjectMap.init(allocator);
                try tx_map.put("hash", std.json.Value{ .string = try hex.encodeBuffer(&buf, &tx.hash().bytes) });
                try tx_map.put("nonce", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{tx.nonce}) });
                try tx_map.put("blockNumber", map.get("number").?);
                try tx_map.put("transactionIndex", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{i}) });
                try tx_map.put("from", std.json.Value{ .string = try hex.encodeBuffer(&buf, &tx.from.bytes) });
                if (tx.to) |to| {
                    try tx_map.put("to", std.json.Value{ .string = try hex.encodeBuffer(&buf, &to.bytes) });
                } else {
                    try tx_map.put("to", std.json.Value.null);
                }
                try tx_map.put("value", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{tx.value}) });
                try tx_map.put("gas", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{tx.gas_limit}) });
                try tx_map.put("gasPrice", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{tx.gas_price}) });
                try tx_map.put("input", std.json.Value{ .string = try hex.encode(allocator, tx.data) });

                try txs.append(std.json.Value{ .object = tx_map });
            } else {
                try txs.append(std.json.Value{ .string = try hex.encodeBuffer(&buf, &tx.hash().bytes) });
            }
        }
        try map.put("transactions", std.json.Value{ .array = txs });

        // Timestamp
        try map.put("timestamp", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{block.header.time}) });
        try map.put("gasLimit", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{block.header.gas_limit}) });
        try map.put("gasUsed", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{block.header.gas_used}) });
        try map.put("baseFeePerGas", std.json.Value{ .string = "0x430e23400" });

        return std.json.Value{ .object = map };
    }
    fn eth_getBlockByNumber(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        if (params != .array or params.array.items.len < 1) return error.InvalidParams;
        const block_tag = params.array.items[0].string;
        const full_tx = if (params.array.items.len > 1) params.array.items[1].bool else false;

        var block: ?*types.Block = null;

        if (std.mem.eql(u8, block_tag, "latest")) {
            if (self.chain.current_block) |head| {
                // Return copy via get_block_by_number using head number
                block = self.chain.get_block_by_number(head.header.number);
            }
            // Fallback: use get_block_by_number with current height if head is null or whatever logic
            // Actually self.chain.current_block might be the way.
            // Let's assume get_block_by_number works.
            // block = self.chain.get_block_by_number(self.chain.height);
            // Let's stick to safe path: parse hex or special tags.
        }

        if (block == null) {
            // Try parsing number
            if (std.mem.startsWith(u8, block_tag, "0x")) {
                const num = std.fmt.parseInt(u64, block_tag[2..], 16) catch return error.InvalidParams;
                block = self.chain.get_block_by_number(num);
            } else if (std.mem.eql(u8, block_tag, "latest")) {
                // If current_block is null, maybe genesis?
                // self.chain.current_block is ?*Block
                if (self.chain.current_block) |head| {
                    block = self.chain.get_block_by_number(head.header.number);
                }
            } else if (std.mem.eql(u8, block_tag, "earliest")) {
                block = self.chain.get_block_by_number(0);
            }
        }

        if (block) |b| {
            defer self.chain.free_block(b);
            return self.formatBlock(allocator, b, full_tx);
        }
        return std.json.Value.null;
    }
    fn eth_getTransactionReceipt(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        if (params != .array or params.array.items.len < 1) return error.InvalidParams;
        const tx_hash_hex = params.array.items[0].string;

        var tx_hash: types.Hash = undefined;
        _ = try @import("utils").hex.decode(allocator, tx_hash_hex); // Validate format
        const bytes = try std.fmt.hexToBytes(&tx_hash.bytes, std.mem.trimLeft(u8, tx_hash_hex, "0x"));
        if (bytes.len != 32) return error.InvalidParams;

        // 1. Get Transaction Location
        if (try self.chain.get_transaction_location(tx_hash)) |loc| {
            // 2. Get Block
            if (try self.chain.get_block_by_hash(loc.block_hash)) |block| {
                defer self.chain.free_block(block);

                // 3. Find Transaction (we know index)
                if (loc.tx_index >= block.transactions.len) {
                    std.debug.print("[RPC] Tx index {} out of bounds (len {})\n", .{ loc.tx_index, block.transactions.len });
                    return std.json.Value.null;
                }
                const tx = block.transactions[loc.tx_index];

                // 4. Construct Receipt
                var map = std.json.ObjectMap.init(allocator);

                try map.put("transactionHash", std.json.Value{ .string = try @import("utils").hex.encode(allocator, &tx_hash.bytes) });
                try map.put("transactionIndex", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{loc.tx_index}) });
                try map.put("blockHash", std.json.Value{ .string = try @import("utils").hex.encode(allocator, &loc.block_hash.bytes) });
                try map.put("blockNumber", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{block.header.number}) });
                try map.put("from", std.json.Value{ .string = try @import("utils").hex.encode(allocator, &tx.from.bytes) });

                if (tx.to) |to| {
                    try map.put("to", std.json.Value{ .string = try @import("utils").hex.encode(allocator, &to.bytes) });
                    try map.put("contractAddress", std.json.Value.null);
                } else {
                    try map.put("to", std.json.Value.null);
                    try map.put("contractAddress", std.json.Value.null);
                }

                try map.put("cumulativeGasUsed", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{21000}) });
                try map.put("gasUsed", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{21000}) });
                try map.put("status", std.json.Value{ .string = "0x1" });
                try map.put("logs", std.json.Value{ .array = std.json.Array.init(allocator) });
                try map.put("logsBloom", std.json.Value{ .string = "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" });

                return std.json.Value{ .object = map };
            }
        }

        return std.json.Value.null;
    }

    fn eth_getBlockByHash(self: *RpcHandler, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        if (params != .array or params.array.items.len < 1) return error.InvalidParams;
        const block_hash_hex = params.array.items[0].string;
        const full_tx = if (params.array.items.len > 1) params.array.items[1].bool else false;

        var block_hash: types.Hash = undefined;
        _ = try @import("utils").hex.decode(allocator, block_hash_hex);
        const bytes = try std.fmt.hexToBytes(&block_hash.bytes, std.mem.trimLeft(u8, block_hash_hex, "0x"));
        if (bytes.len != 32) return error.InvalidParams;

        if (try self.chain.get_block_by_hash(block_hash)) |block| {
            defer self.chain.free_block(block);
            return self.formatBlock(allocator, block, full_tx);
        }
        return std.json.Value.null;
    }
};
