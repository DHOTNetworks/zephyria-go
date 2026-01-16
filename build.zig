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
    if (b.lazyDependency("verkle_crypto", .{
        .target = target,
        .optimize = optimize,
    })) |verkle_dep| {
        storage_test.root_module.addImport("verkle-crypto", verkle_dep.module("verkle-crypto"));
    }

    const run_storage_test = b.addRunArtifact(storage_test);
    test_step.dependOn(&run_storage_test.step);
}
