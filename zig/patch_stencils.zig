const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var dir = try std.fs.cwd().openDir("src/vm/stencils", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const content = try dir.readFileAlloc(allocator, entry.name, 10 * 1024);
            defer allocator.free(content);

            var new_content = std.ArrayListUnmanaged(u8){};
            defer new_content.deinit(allocator);

            var changed = false;
            var line_it = std.mem.splitSequence(u8, content, "\n");
            while (line_it.next()) |line| {
                if (std.mem.indexOf(u8, line, "export fn stencil_") != null and std.mem.indexOf(u8, line, "evm: *anyopaque") == null) {
                    // Update signature: (stack: [*]u256) -> (stack: [*]u256, evm: *anyopaque)
                    const updated = try std.mem.replaceOwned(u8, allocator, line, "(stack: [*]u256)", "(stack: [*]u256, evm: *anyopaque)");
                    defer allocator.free(updated);
                    try new_content.appendSlice(allocator, updated);
                    changed = true;
                } else {
                    try new_content.appendSlice(allocator, line);
                }
                try new_content.appendSlice(allocator, "\n");
            }

            if (changed) {
                try dir.writeFile(.{ .sub_path = entry.name, .data = new_content.items });
                std.debug.print("Updated signature in {s}\n", .{entry.name});
            }
        }
    }
}
