const std = @import("std");
pub const types = @import("types.zig");
pub const server = @import("server.zig");
pub const peer = @import("peer.zig");

// Export key structs
pub const Server = server.Server;
pub const Peer = peer.Peer;

pub fn init() void {
    std.debug.print("P2P module initialized\n", .{});
}
