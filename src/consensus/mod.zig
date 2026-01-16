const std = @import("std");
pub const types = @import("types.zig");
pub const registry = @import("registry.zig");
pub const vdf = @import("vdf.zig");
pub const vrf = @import("vrf.zig");
pub const zelius = @import("zelius.zig"); // Export Zelius
pub const votepool = @import("votepool.zig");

// Re-export specific structs for easier access
pub const ValidatorInfo = types.ValidatorInfo;
pub const ValidatorRegistry = registry.ValidatorRegistry;
pub const VDF = vdf.VDF;
pub const VRF = vrf.VRF;
pub const ZeliusEngine = zelius.ZeliusEngine;
pub const VotePool = votepool.VotePool;

pub fn init() void {
    std.debug.print("Consensus module initialized with VDF/VRF/Zelius\n", .{});
}
