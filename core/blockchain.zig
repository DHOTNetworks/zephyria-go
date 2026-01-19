const std = @import("std");
const types = @import("types.zig");
const storage = @import("storage");
const DB = storage.DB;

pub const Blockchain = struct {
    allocator: std.mem.Allocator,
    db: DB,
    current_block: ?*types.Block,
    chain_id: u64,
    genesis_hash: types.Hash,
    lock: std.Thread.RwLock,

    pub fn init(allocator: std.mem.Allocator, db: DB, chain_id: u64) !*Blockchain {
        const self = try allocator.create(Blockchain);
        self.* = Blockchain{
            .allocator = allocator,
            .db = db,
            .current_block = null,
            .chain_id = chain_id,
            .genesis_hash = types.Hash.zero(),
            .lock = .{},
        };

        // Try to load head hash
        if (db.read("head")) |hash_bytes| {
            std.debug.print("DISK: Found 'head' key in DB (len={d})\n", .{hash_bytes.len});
            if (hash_bytes.len == 32) {
                var hash: types.Hash = undefined;
                @memcpy(&hash.bytes, hash_bytes[0..32]);
                if (try self.get_block_by_hash(hash)) |block| {
                    self.current_block = block;
                }
            }
        } else {
            std.debug.print("DISK: No 'head' key found in DB.\n", .{});
        }

        // Try to load genesis hash (block #0)
        var gen_key: [10]u8 = undefined;
        @memcpy(gen_key[0..2], "H-");
        std.mem.writeInt(u64, gen_key[2..10], 0, .big);
        if (db.read(&gen_key)) |hash_bytes| {
            if (hash_bytes.len == 32) {
                @memcpy(&self.genesis_hash.bytes, hash_bytes[0..32]);
            }
        }

        return self;
    }

    pub fn deinit(self: *Blockchain) void {
        if (self.current_block) |block| {
            self.free_block(block);
        }
        self.allocator.destroy(self);
    }

    pub fn set_genesis_hash(self: *Blockchain, hash: types.Hash) void {
        self.genesis_hash = hash;
    }

    pub fn get_head(self: *Blockchain) ?*types.Block {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.current_block;
    }

    pub fn get_head_hash(self: *Blockchain) types.Hash {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.current_block) |block| {
            return block.hash();
        }
        return types.Hash.zero();
    }

    pub fn get_head_number(self: *Blockchain) u64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.current_block) |block| {
            return block.header.number;
        }
        return 0;
    }

    pub fn set_head(self: *Blockchain, block: *types.Block) void {
        if (self.current_block) |old| {
            if (old != block) self.free_block(old);
        }
        self.current_block = block;
        // Persist head
        self.db.write("head", &block.hash().bytes) catch {};
    }

    pub fn free_block(self: *Blockchain, block: *types.Block) void {
        block.deinit(self.allocator);
        self.allocator.destroy(block);
    }

    /// AddBlock adds a block to the chain (validates and stores)
    pub fn add_block(self: *Blockchain, block: *types.Block) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Persist block
        try self.store_block(block);

        // Persist Tx Lookup Index
        for (block.transactions, 0..) |*tx, i| {
            const tx_hash = tx.hash();
            const key = try std.fmt.allocPrint(self.allocator, "tx_lookup_{s}", .{tx_hash.bytes});
            defer self.allocator.free(key);

            // Value: BlockHash (32) + TxIndex (8)
            var value: [40]u8 = undefined;
            const block_hash = block.hash();
            @memcpy(value[0..32], &block_hash.bytes);
            std.mem.writeInt(u64, value[32..40], i, .big);

            try self.db.write(key, &value);
        }

        // Update Head logic (Fork Choice: Longest Chain)
        var update_head = false;
        if (self.current_block == null) {
            update_head = true;
        } else {
            if (block.header.number > self.current_block.?.header.number) {
                update_head = true;
            } else if (block.header.number == self.current_block.?.header.number) {
                // Tiebreaker: Higher Hash
                if (std.mem.order(u8, &block.hash().bytes, &self.current_block.?.hash().bytes) == .gt) {
                    update_head = true;
                }
            }
        }

        if (update_head) {
            self.set_head(block);
            // Write canonical mapping
            var key: [10]u8 = undefined;
            @memcpy(key[0..2], "H-");
            std.mem.writeInt(u64, key[2..10], block.header.number, .big);
            try self.db.write(&key, &block.hash().bytes);
        }
    }

    fn store_block(self: *Blockchain, block: *types.Block) !void {
        // Internal: Assumes lock held if modifying state, but here it just writes DB.
        // DB access inside lock is fine.
        const h = block.hash();
        var key: [34]u8 = undefined;
        @memcpy(key[0..2], "b-");
        @memcpy(key[2..34], &h.bytes);

        // Serialize block using RLP (includes Header and Transactions)
        const encoded = try @import("encoding").rlp.encode(self.allocator, block.*);
        defer self.allocator.free(encoded);

        std.debug.print("DISK: Storing block #{d}, size={d} bytes\n", .{ block.header.number, encoded.len });
        try self.db.write(&key, encoded);
    }

    pub fn get_block_by_hash(self: *Blockchain, hash: types.Hash) !?*types.Block {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var key: [34]u8 = undefined;
        @memcpy(key[0..2], "b-");
        @memcpy(key[2..34], &hash.bytes);

        const data = self.db.read(&key) orelse {
            std.debug.print("DISK: Failed to find block data for hash (len={d})\n", .{hash.bytes.len});
            return null;
        };

        // Deserialize using RLP
        const block = try self.allocator.create(types.Block);
        errdefer self.allocator.destroy(block);

        block.* = try @import("encoding").rlp.decode(self.allocator, types.Block, data);

        // Recover 'from' address for all transactions
        const tx_decode = @import("tx_decode.zig");
        for (block.transactions) |*tx| {
            tx.from = tx_decode.recoverFromTx(self.allocator, tx.*) catch |err| {
                std.debug.print("Failed to recover sender for tx: {}\n", .{err});
                return err;
            };
        }

        return block;
    }

    pub fn get_block_by_number(self: *Blockchain, number: u64) ?*types.Block {
        // Lock inside get_block_by_hash, so we need to be careful not to hold lock here if calling that.
        // Wait, Recursive locking? RwLock is not recursive usually.
        // get_block_by_number reads from DB to find hash, THEN calls get_block_by_hash.
        // We should lock for the DB read, unlock, then call get_block_by_hash (which locks again).
        // OR we hold lock and call an unsafe internal version.
        // Simpler: Just Read DB with lock, get Hash, Unlock, Call get_block_by_hash.

        var hash: types.Hash = undefined;
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            var key: [10]u8 = undefined;
            @memcpy(key[0..2], "H-");
            std.mem.writeInt(u64, key[2..10], number, .big);

            const hash_bytes = self.db.read(&key) orelse return null;
            @memcpy(&hash.bytes, hash_bytes[0..32]);
        }

        return self.get_block_by_hash(hash) catch null;
    }

    /// CalcBaseFee implementation of EIP-1559
    pub fn calc_base_fee(parent: *const types.Header) u256 {
        // Simple EIP-1559 logic
        const elasticity_multiplier = @as(u64, 2);
        const base_fee_change_denominator = @as(u64, 8);
        const initial_base_fee = @as(u256, 1_000_000_000); // 1 Gwei

        if (parent.number == 0) return initial_base_fee;

        const parent_gas_target = parent.gas_limit / elasticity_multiplier;

        if (parent.gas_used == parent_gas_target) {
            return parent.base_fee;
        }

        if (parent.gas_used > parent_gas_target) {
            const gas_used_delta = parent.gas_used - parent_gas_target;
            const num = parent.base_fee * @as(u256, gas_used_delta);
            const den = @as(u256, parent_gas_target) * @as(u256, base_fee_change_denominator);
            var delta = num / den;
            if (delta < 1) delta = 1;
            return parent.base_fee + delta;
        } else {
            const gas_unused_delta = parent_gas_target - parent.gas_used;
            const num = parent.base_fee * @as(u256, gas_unused_delta);
            const den = @as(u256, parent_gas_target) * @as(u256, base_fee_change_denominator);
            const delta = num / den;

            const floor = @as(u256, 7); // Minimum base fee
            if (parent.base_fee > delta + floor) {
                return parent.base_fee - delta;
            }
            return floor;
        }
    }

    pub const TxLocation = struct {
        block_hash: types.Hash,
        tx_index: u64,
    };

    pub fn get_transaction_location(self: *Blockchain, tx_hash: types.Hash) !?TxLocation {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const key = try std.fmt.allocPrint(self.allocator, "tx_lookup_{s}", .{tx_hash.bytes});
        defer self.allocator.free(key);

        if (self.db.read(key)) |value| {
            if (value.len != 40) return null;
            var loc: TxLocation = undefined;
            @memcpy(&loc.block_hash.bytes, value[0..32]);
            loc.tx_index = std.mem.readInt(u64, value[32..40], .big);
            return loc;
        }
        return null;
    }
};
