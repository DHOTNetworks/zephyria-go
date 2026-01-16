const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules
    const storage_mod = b.addModule("storage", .{
        .root_source_file = b.path("src/storage/mod.zig"),
    });

    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/main.zig"),
    });

    const consensus_mod = b.addModule("consensus", .{
        .root_source_file = b.path("src/consensus/mod.zig"),
    });

    const p2p_mod = b.addModule("p2p", .{
        .root_source_file = b.path("src/p2p/mod.zig"),
    });

    const rpc_mod = b.addModule("rpc", .{
        .root_source_file = b.path("src/rpc/mod.zig"),
    });

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/mod.zig"),
    });

    const node_mod = b.addModule("node", .{
        .root_source_file = b.path("src/node/mod.zig"),
    });

    const encoding_mod = b.addModule("encoding", .{
        .root_source_file = b.path("src/encoding/mod.zig"),
    });

    const utils_mod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/mod.zig"),
    });

    const net_utils_mod = b.addModule("net_utils", .{
        .root_source_file = b.path("src/net/mod.zig"),
    });

    // Stencil Generator Tool
    const generator_exe = b.addExecutable(.{
        .name = "stencil_generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm/generator/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(generator_exe);

    // Run Generator
    const run_generator = b.addRunArtifact(generator_exe);
    const generated_stencils_path = "src/vm/generated/stencils.zig";
    const stencils_file = run_generator.addOutputFileArg(generated_stencils_path);

    // Automated Stencil Discovery
    const stencil_dir_path = "src/vm/stencils";
    var stencil_dir = b.build_root.handle.openDir(stencil_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: could not open stencil directory {s}: {}\n", .{ stencil_dir_path, err });
        return;
    };
    defer stencil_dir.close();

    var walker = stencil_dir.walk(b.allocator) catch unreachable;
    defer walker.deinit();

    while (walker.next() catch unreachable) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
            // Skip context.zig if it's just a bridge/helper file
            if (std.mem.eql(u8, entry.basename, "context.zig")) continue;

            const name = b.fmt("stencil_{s}", .{entry.basename[0 .. entry.basename.len - 4]});
            const obj = b.addObject(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.pathJoin(&.{ stencil_dir_path, entry.path })),
                    .target = target,
                    .optimize = .ReleaseFast,
                }),
            });
            run_generator.addFileArg(obj.getEmittedBin());
        }
    }

    const gen_step = b.step("gen-stencils", "Generate VM stencils");
    gen_step.dependOn(&run_generator.step);

    // Expose generated stencils as a module
    const stencils_mod = b.addModule("stencils", .{
        .root_source_file = stencils_file,
    });
    // VM depends on stencils
    vm_mod.addImport("stencils", stencils_mod);

    // Dependencies

    // blst
    if (b.lazyDependency("blst", .{
        .target = target,
        .optimize = optimize,
    })) |blst_dep| {
        consensus_mod.addImport("blst", blst_dep.module("blst"));
    }

    // zig-quic (Locally Vendored)
    if (b.lazyDependency("zig_quic", .{
        .target = target,
        .optimize = optimize,
    })) |quic_dep| {
        p2p_mod.addImport("zig-quic", quic_dep.module("zig-quic"));
    }

    // verkle-crypto
    if (b.lazyDependency("verkle_crypto", .{
        .target = target,
        .optimize = optimize,
    })) |verkle_dep| {
        storage_mod.addImport("verkle-crypto", verkle_dep.module("verkle-crypto"));
    }

    if (b.lazyDependency("grpc", .{
        .target = target,
        .optimize = optimize,
    })) |grpc_dep| {
        rpc_mod.addImport("grpc", grpc_dep.module("grpc-server"));
        // Also add to exe if needed, but rpc_mod should be enough
    }

    // Main Executable
    const exe = b.addExecutable(.{
        .name = "zephyria",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add internal modules to exe
    exe.root_module.addImport("storage", storage_mod);
    exe.root_module.addImport("vm", vm_mod);
    exe.root_module.addImport("consensus", consensus_mod);
    exe.root_module.addImport("p2p", p2p_mod);
    exe.root_module.addImport("rpc", rpc_mod);
    exe.root_module.addImport("core", core_mod);
    exe.root_module.addImport("node", node_mod);
    exe.root_module.addImport("utils", utils_mod);

    // Dependencies between modules
    core_mod.addImport("storage", storage_mod);
    core_mod.addImport("encoding", encoding_mod);
    core_mod.addImport("utils", utils_mod);

    vm_mod.addImport("core", core_mod);
    consensus_mod.addImport("core", core_mod);

    p2p_mod.addImport("core", core_mod);
    p2p_mod.addImport("consensus", consensus_mod);
    p2p_mod.addImport("encoding", encoding_mod);
    p2p_mod.addImport("utils", utils_mod);
    p2p_mod.addImport("net_utils", net_utils_mod);

    rpc_mod.addImport("core", core_mod);
    rpc_mod.addImport("p2p", p2p_mod);
    rpc_mod.addImport("encoding", encoding_mod);
    rpc_mod.addImport("utils", utils_mod);

    node_mod.addImport("core", core_mod);
    node_mod.addImport("storage", storage_mod);
    node_mod.addImport("consensus", consensus_mod);
    node_mod.addImport("p2p", p2p_mod);

    // Link System Libraries if needed
    exe.linkLibC();
    exe.linkSystemLibrary("z");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run library tests");

    const storage_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // verkle-crypto dependency for tests
    // verkle-crypto dependency for tests
    if (b.lazyDependency("verkle_crypto", .{
        .target = target,
        .optimize = optimize,
    })) |verkle_dep| {
        storage_test.root_module.addImport("verkle-crypto", verkle_dep.module("verkle-crypto"));
    }

    const run_storage_test = b.addRunArtifact(storage_test);
    test_step.dependOn(&run_storage_test.step);

    // JIT Verification Test Executable
    const test_jit_exe = b.addExecutable(.{
        .name = "test_jit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm/tests/test_jit.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // Add dependencies
    test_jit_exe.root_module.addImport("vm", vm_mod);
    test_jit_exe.linkLibC();

    const run_test_jit = b.addRunArtifact(test_jit_exe);
    const test_jit_step = b.step("test-jit", "Run JIT verification test");
    test_jit_step.dependOn(&run_test_jit.step);

    // Automated Opcode Index Generation
    const opcode_dir_path = "src/vm/opcodes";
    const generated_index_path = "src/vm/opcodes/index.zig";

    const gen_index_step = b.allocator.create(std.Build.Step) catch unreachable;
    gen_index_step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "generate-opcode-index",
        .owner = b,
        .makeFn = struct {
            fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
                _ = options;
                const self: *std.Build.Step = step;
                const b_inner = self.owner;

                var dir = try b_inner.build_root.handle.openDir(opcode_dir_path, .{ .iterate = true });
                defer dir.close();

                var out_file = try b_inner.build_root.handle.createFile(generated_index_path, .{});
                defer out_file.close();

                // Use a simple buffer for writing
                var buf: [1024]u8 = undefined;

                try out_file.writeAll("// Auto-generated opcode index. Do not edit.\n");
                try out_file.writeAll("const std = @import(\"std\");\n\n");

                var opcode_walker = try dir.walk(b_inner.allocator);
                defer opcode_walker.deinit();

                var opcode_names = std.ArrayListUnmanaged([]const u8){};
                defer {
                    for (opcode_names.items) |name| b_inner.allocator.free(name);
                    opcode_names.deinit(b_inner.allocator);
                }

                while (try opcode_walker.next()) |entry| {
                    if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
                        if (std.mem.eql(u8, entry.basename, "index.zig")) continue;
                        if (std.mem.eql(u8, entry.basename, "mod.zig")) {
                            try opcode_names.append(b_inner.allocator, try b_inner.allocator.dupe(u8, "mod"));
                        } else {
                            const name = entry.basename[0 .. entry.basename.len - 4];
                            try opcode_names.append(b_inner.allocator, try b_inner.allocator.dupe(u8, name));
                        }
                    }
                }

                // Sort names for deterministic generation
                std.mem.sort([]const u8, opcode_names.items, {}, struct {
                    fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.lessThan(u8, lhs, rhs);
                    }
                }.lessThan);

                for (opcode_names.items) |name| {
                    const is_keyword = std.mem.eql(u8, name, "and") or
                        std.mem.eql(u8, name, "or") or
                        std.mem.eql(u8, name, "return") or
                        std.mem.eql(u8, name, "xor") or
                        std.mem.eql(u8, name, "not");

                    if (is_keyword) {
                        const line = try std.fmt.bufPrint(&buf, "pub const @\"{s}\" = @import(\"{s}.zig\");\n", .{ name, name });
                        try out_file.writeAll(line);
                    } else {
                        const line = try std.fmt.bufPrint(&buf, "pub const {s} = @import(\"{s}.zig\");\n", .{ name, name });
                        try out_file.writeAll(line);
                    }
                }

                try out_file.writeAll("\npub const all_opcodes = [_]type {\n");
                for (opcode_names.items) |name| {
                    const is_keyword = std.mem.eql(u8, name, "and") or
                        std.mem.eql(u8, name, "or") or
                        std.mem.eql(u8, name, "return") or
                        std.mem.eql(u8, name, "xor") or
                        std.mem.eql(u8, name, "not");

                    if (is_keyword) {
                        const line = try std.fmt.bufPrint(&buf, "    @\"{s}\",\n", .{name});
                        try out_file.writeAll(line);
                    } else {
                        const line = try std.fmt.bufPrint(&buf, "    {s},\n", .{name});
                        try out_file.writeAll(line);
                    }
                }
                try out_file.writeAll("};\n");
            }
        }.make,
    });

    const gen_index_cmd = b.step("gen-opcode-index", "Generate opcode index");
    gen_index_cmd.dependOn(gen_index_step);

    // Ensure index is generated before building the VM
    b.getInstallStep().dependOn(gen_index_step);
}
