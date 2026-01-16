pub const packages = struct {
    pub const @"12201203010a7c0990e2e0e173dbe4bb01eb4648c4784631d5a08f57098ad1743776" = struct {
        pub const build_root = "/Users/karan/.cache/zig/p/spice-0.0.0-3FtxfEq9AAASAwEKfAmQ4uDhc9vkuwHrRkjEeEYx1aCP";
        pub const build_zig = @import("12201203010a7c0990e2e0e173dbe4bb01eb4648c4784631d5a08f57098ad1743776");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "parg", "parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP" },
        };
    };
    pub const @"1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb" = struct {
        pub const build_root = "/Users/karan/.cache/zig/p/N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"N-V-__8AAKDMOgDp0ule4-ieF6xoW2euEGpOwOyBPo-KRj_a" = struct {
        pub const build_root = "/Users/karan/.cache/zig/p/N-V-__8AAKDMOgDp0ule4-ieF6xoW2euEGpOwOyBPo-KRj_a";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"libs/blst-wrapper" = struct {
        pub const build_root = "/Users/karan/zephyria/zig/libs/blst-wrapper";
        pub const build_zig = @import("libs/blst-wrapper");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "blst", "N-V-__8AAKDMOgDp0ule4-ieF6xoW2euEGpOwOyBPo-KRj_a" },
        };
    };
    pub const @"libs/blst-z" = struct {
        pub const build_root = "/Users/karan/zephyria/zig/libs/blst-z";
        pub const build_zig = @import("libs/blst-z");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "blst", "libs/blst-wrapper" },
        };
    };
    pub const @"libs/grpc-zig" = struct {
        pub const build_root = "/Users/karan/zephyria/zig/libs/grpc-zig";
        pub const build_zig = @import("libs/grpc-zig");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "spice", "12201203010a7c0990e2e0e173dbe4bb01eb4648c4784631d5a08f57098ad1743776" },
            .{ "zlib", "1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb" },
        };
    };
    pub const @"libs/verkle-crypto" = struct {
        pub const build_root = "/Users/karan/zephyria/zig/libs/verkle-crypto";
        pub const build_zig = @import("libs/verkle-crypto");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"libs/zig-quic" = struct {
        pub const build_root = "/Users/karan/zephyria/zig/libs/zig-quic";
        pub const build_zig = @import("libs/zig-quic");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"parg-0.0.0-dOPWZNhYAABEHE6EGXmwIucnu9vj-emodT9vmHeYynAP" = struct {
        pub const available = false;
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "blst", "libs/blst-z" },
    .{ "zig_quic", "libs/zig-quic" },
    .{ "verkle_crypto", "libs/verkle-crypto" },
    .{ "grpc", "libs/grpc-zig" },
};
