const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var dir = try std.fs.cwd().openDir("src/vm/opcodes", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "push") and std.mem.endsWith(u8, entry.name, ".zig")) {
            const num_str = entry.name[4 .. entry.name.len - 4];
            const size = std.fmt.parseInt(usize, num_str, 10) catch continue;
            if (size == 1) continue;

            const content = try dir.readFileAlloc(allocator, entry.name, 10 * 1024);
            defer allocator.free(content);

            if (std.mem.indexOf(u8, content, "pub fn jit_compile") != null) continue;

            var new_content = std.ArrayListUnmanaged(u8){};
            defer new_content.deinit(allocator);
            try new_content.appendSlice(allocator, content);

            const jit_logic = try std.fmt.allocPrint(allocator, "\npub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {{\n" ++
                "    const size = {d};\n" ++
                "    if (pc.* + size > bytecode.len) return error.InvalidCode;\n" ++
                "    var val: u256 = 0;\n" ++
                "    var i: usize = 0;\n" ++
                "    while (i < size) : (i += 1) {{\n" ++
                "        val = (val << 8) | bytecode[pc.* + i];\n" ++
                "    }}\n" ++
                "    pc.* += size;\n" ++
                "    try jit.compile_push(stack_top.*, val);\n" ++
                "    stack_top.* += 1;\n" ++
                "}}\n", .{size});
            defer allocator.free(jit_logic);
            try new_content.appendSlice(allocator, jit_logic);

            try dir.writeFile(.{ .sub_path = entry.name, .data = new_content.items });
            std.debug.print("Patched {s}\n", .{entry.name});
        }
    }
}
