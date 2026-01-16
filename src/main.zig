const std = @import("std");
const vm = @import("vm");
const core = @import("core");
const storage = @import("storage");
const consensus = @import("consensus");
const rpc = @import("rpc");
const p2p = @import("p2p");
const node = @import("node");

// Import core types directly
const types = core.types;
const Block = types.Block;
const Header = types.Header;
const Address = types.Address;
const Hash = types.Hash;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run-jit")) {
        try runJitTest(allocator);
    } else if (std.mem.eql(u8, command, "show-block")) {
        try showBlock(allocator);
    } else if (std.mem.eql(u8, command, "start")) {
        try startNode(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "account")) {
        try handleAccountCommand(allocator, args[2..]);
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\
        \\  ╔═══════════════════════════════════════════╗
        \\  ║      🌀 ZEPHYRIA NODE (Zig Edition)       ║
        \\  ╚═══════════════════════════════════════════╝
        \\
        \\Usage: zephyria <command> [options]
        \\
        \\Commands:
        \\  start       🚀 Start the full node
        \\  run-jit     ⚡ Run sample EVM bytecode through JIT
        \\  show-block  📦 Show block details (Mock)
        \\  account     🔑 Account management (new, list)
        \\
        \\Options:
        \\  --port      P2P listening port (default: 30303)
        \\  --http.port HTTP-RPC port (default: 8545)
        \\  --datadir   Data directory path
        \\  --network   Network name (devnet, testnet, mainnet)
        \\  --mine      Start mining immediately
        \\  --password  Password for keystore operations
        \\
    , .{});
}

fn runJitTest(allocator: std.mem.Allocator) !void {
    std.debug.print("⚡ Initializing VM for JIT Test...\n", .{});

    var evm = try vm.EVM.init(allocator);
    defer evm.deinit();

    const bytecode = &[_]u8{
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x01, // ADD
        0x60, 0x02, // PUSH1 2
        0x02, // MUL
        0x00, // STOP
    };

    evm.code = bytecode;
    evm.pc = 0;
    evm.gas = 100000;

    std.debug.print("📜 Bytecode: {s}\n", .{try @import("utils").hex.encode(allocator, bytecode)});

    try evm.execute();

    std.debug.print("✅ Execution Completed.\n", .{});

    if (evm.stack.pop()) |result| {
        std.debug.print("📊 Result: {d} (0x{x})\n", .{ result.toU64(), result.toU64() });
    } else {
        std.debug.print("❌ Error: Stack is empty!\n", .{});
    }
}

fn handleAccountCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zephyria account <new|list> [options]\n", .{});
        return;
    }

    const sub = args[0];
    var password: []const u8 = "password"; // Default
    var data_dir: []const u8 = "./node_data";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--password")) {
            if (i + 1 < args.len) {
                password = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--datadir")) {
            if (i + 1 < args.len) {
                data_dir = args[i + 1];
                i += 1;
            }
        }
    }

    const keystore_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "keystore" });
    defer allocator.free(keystore_dir_path);
    try std.fs.cwd().makePath(keystore_dir_path);

    if (std.mem.eql(u8, sub, "new")) {
        std.debug.print("🔑 Generating new account...\n", .{});
        var priv_key: [32]u8 = undefined;
        std.crypto.random.bytes(&priv_key);

        const json = try core.account.encrypt(allocator, priv_key, password);
        defer allocator.free(json);

        const addr = try core.account.addressFromPrivKey(priv_key);
        var addr_buf: [42]u8 = undefined;
        const addr_hex = try @import("utils").hex.encodeBuffer(&addr_buf, &addr.bytes);

        const filename = try std.fmt.allocPrint(allocator, "UTC--{d}--{s}.json", .{ std.time.timestamp(), std.mem.trimLeft(u8, addr_hex, "0x") });
        defer allocator.free(filename);

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ keystore_dir_path, filename });
        defer allocator.free(full_path);

        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();
        try file.writeAll(json);

        std.debug.print("✅ Created new account: {s}\n", .{addr_hex});
        std.debug.print("   Saved to: {s}\n", .{full_path});
    } else if (std.mem.eql(u8, sub, "list")) {
        std.debug.print("🔑 Local Accounts:\n", .{});
        var dir = try std.fs.cwd().openDir(keystore_dir_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                const content = try dir.readFileAlloc(allocator, entry.name, 1024 * 64);
                defer allocator.free(content);

                // Quick parse to get address
                const parsed = try std.json.parseFromSlice(core.account.KeystoreV3, allocator, content, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();

                std.debug.print("   0x{s} ({s})\n", .{ parsed.value.address, entry.name });
            }
        }
    } else {
        std.debug.print("Unknown account subcommand: {s}\n", .{sub});
    }
}

fn showBlock(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const header = Header{
        .parent_hash = Hash.zero(),
        .coinbase = Address.zero(),
        .verkle_root = Hash{ .bytes = [_]u8{0xAA} ** 32 },
        .tx_hash = Hash.zero(),
        .number = 1,
        .gas_limit = 30_000_000,
        .gas_used = 21000,
        .time = @intCast(std.time.timestamp()),
        .extra_data = &[_]u8{},
        .base_fee = 10,
    };

    const block = Block{
        .header = header,
        .transactions = &[_]core.types.Transaction{},
    };

    const hash = block.hash();

    std.debug.print("\n📦 Block #{d}\n", .{header.number});
    std.debug.print("   Hash:       {f}\n", .{hash});
    std.debug.print("   State Root: {f}\n", .{header.verkle_root});
    std.debug.print("   Gas Used:   {d}\n", .{header.gas_used});
}

var running = std.atomic.Value(bool).init(true);

fn sigHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    running.store(false, .seq_cst);
    std.debug.print("\n🛑 Received signal, shutting down...\n", .{});
}

fn startNode(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // 0. Parse Args
    var p2p_port: u16 = 30303;
    var http_port: u16 = 8545;
    var data_dir: []const u8 = "./node_data";
    var network_name: []const u8 = "devnet";
    var should_mine: bool = false;
    var miner_key_hex: ?[]const u8 = null;
    var miner_keystore_path: ?[]const u8 = null;
    var password: []const u8 = "password";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            if (i + 1 < args.len) {
                p2p_port = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--http.port")) {
            if (i + 1 < args.len) {
                http_port = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--datadir")) {
            if (i + 1 < args.len) {
                data_dir = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--network")) {
            if (i + 1 < args.len) {
                network_name = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--mine")) {
            should_mine = true;
        } else if (std.mem.eql(u8, args[i], "--miner.key")) {
            if (i + 1 < args.len) {
                miner_key_hex = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--miner.keystore")) {
            if (i + 1 < args.len) {
                miner_keystore_path = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--password")) {
            if (i + 1 < args.len) {
                password = args[i + 1];
                i += 1;
            }
        }
    }

    // Setup signal handling
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = sigHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    }, null);

    // Banner
    std.debug.print(
        \\
        \\  ╔═══════════════════════════════════════════╗
        \\  ║   🚀 Starting Zephyria Interactive Node   ║
        \\  ╚═══════════════════════════════════════════╝
        \\
    , .{});

    // 1. Storage & State (LSM + Verkle)
    std.debug.print("📁 Initializing Storage...\n", .{});
    try std.fs.cwd().makePath(data_dir);
    var db = try storage.lsm.db.DB.init(allocator, data_dir);
    defer db.deinit();

    var trie = try storage.verkle.trie.VerkleTrie.init(allocator, db.asAbstractDB());
    defer trie.deinit();

    var world_state = core.state.State.init(allocator, &trie);
    defer world_state.deinit();

    // 2. Genesis & Blockchain
    std.debug.print("🔧 Loading Configuration...\n", .{});
    const network = core.genesis.getNetworkConfig(network_name);

    // Determine Miner Identity
    var miner_priv_key: [32]u8 = undefined;
    var validator_addr: Address = undefined;

    if (miner_key_hex) |hex_str| {
        const decoded = try @import("utils").hex.decode(allocator, hex_str);
        defer allocator.free(decoded);
        @memcpy(&miner_priv_key, decoded[0..32]);
        validator_addr = try core.account.addressFromPrivKey(miner_priv_key);
    } else if (miner_keystore_path) |path| {
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 64);
        defer allocator.free(content);
        miner_priv_key = try core.account.decrypt(allocator, content, password);
        validator_addr = try core.account.addressFromPrivKey(miner_priv_key);
    } else {
        // Fallback to dev key if devnet
        if (std.mem.eql(u8, network_name, "devnet")) {
            const dev_key = try @import("utils").hex.decode(allocator, "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291");
            defer allocator.free(dev_key);
            @memcpy(&miner_priv_key, dev_key[0..32]);
            validator_addr = try core.account.addressFromPrivKey(miner_priv_key);
        } else {
            return error.MinerKeyRequired;
        }
    }

    var chain = try core.blockchain.Blockchain.init(allocator, db.asAbstractDB(), @as(u64, @intCast(network.chain_id)));
    defer chain.deinit();

    // Check if we need genesis
    var genesis_hash: Hash = Hash.zero();
    if (chain.get_head()) |head| {
        std.debug.print("💾 Resuming from Block #{d} (Hash: {f})\n", .{ head.header.number, head.hash() });
        genesis_hash = head.hash(); // Used for banner, roughly
    } else {
        std.debug.print("✨ Applying Genesis...\n", .{});
        const default_alloc = core.genesis.getDefaultAlloc();
        const genesis_block = try core.genesis.applyGenesis(allocator, &trie, .{
            .config = network,
            .alloc = &default_alloc,
        });
        chain.set_head(genesis_block);
        genesis_hash = genesis_block.hash();
    }
    chain.set_genesis_hash(genesis_hash);

    // 3. Consensus Engine
    std.debug.print("⚙️  Initializing Consensus Engine (Zelius)...\n", .{});
    const engine = try consensus.ZeliusEngine.init(allocator, &[_]consensus.types.ValidatorInfo{}, network.system_params);
    defer engine.deinit();
    engine.set_priv_key(miner_priv_key);
    engine.set_bls_priv_key(&miner_priv_key);

    // 4. Node Components
    var pool = core.tx_pool.TxPool.init(allocator);
    defer pool.deinit();

    var exec = core.executor.Executor.init(allocator, chain, network);

    // 5. Miner
    std.debug.print("⛏️  Initializing Miner...\n", .{});
    var node_miner = try node.Miner.init(allocator, chain, &pool, engine, &exec, &world_state, validator_addr, &running);
    defer node_miner.deinit();

    // 6. P2P Server
    std.debug.print("🌐 Starting P2P Server...\n", .{});
    var p2p_server = try p2p.Server.init(allocator, chain, engine, p2p_port);
    defer p2p_server.deinit();
    node_miner.set_p2p(p2p_server);
    try p2p_server.start();

    // 7. gRPC Server
    var rpc_server = try rpc.Server.init(allocator, http_port, chain, &pool, &exec, &world_state);
    defer rpc_server.deinit();
    rpc_server.set_p2p(p2p_server);
    try rpc_server.start();

    // Summary
    var addr_buf: [42]u8 = undefined;
    const addr_hex = try @import("utils").hex.encodeBuffer(&addr_buf, &validator_addr.bytes);

    std.debug.print(
        \\
        \\✅ Node Running
        \\   Network:    {s}
        \\   Data Dir:   {s}
        \\   Validator:  {s}
        \\   Genesis:    {f}
        \\
        \\   Endpoints:
        \\     P2P:  :{d}
        \\     HTTP: http://127.0.0.1:{d}
        \\
        \\   ethers.js/web3.js compatible!
        \\
    , .{ network_name, data_dir, addr_hex, genesis_hash, p2p_port, http_port });

    // 8. Start mining (blocking)
    if (should_mine) {
        std.debug.print("\n⛏️  Starting Block Production... (Press Ctrl+C to stop)\n\n", .{});
        try node_miner.start();
    } else {
        std.debug.print("\n🟢 Node Ready (Standby mode). Press Ctrl+C to stop.\n\n", .{});
        while (running.load(.seq_cst)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}
