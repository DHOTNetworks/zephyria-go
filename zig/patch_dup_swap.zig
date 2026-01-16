const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var dir = try std.fs.cwd().openDir("src/vm/opcodes", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.startsWith(u8, entry.name, "dup") and std.mem.endsWith(u8, entry.name, ".zig")) {
            const num_str = entry.name[3 .. entry.name.len - 4];
            const n = std.fmt.parseInt(u64, num_str, 10) catch continue;

            const content = try dir.readFileAlloc(allocator, entry.name, 10 * 1024);
            defer allocator.free(content);
            if (std.mem.indexOf(u8, content, "pub fn jit_compile") != null) continue;

            var new_content = std.ArrayListUnmanaged(u8){};
            defer new_content.deinit(allocator);
            try new_content.appendSlice(allocator, content);

            const jit_logic = try std.fmt.allocPrint(allocator, "\npub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {{\n" ++
                "    _ = pc; _ = bytecode;\n" ++
                "    const n = {d};\n" ++
                "    if (stack_top.* < n) return error.StackUnderflow;\n" ++
                "    try jit.compile_move(stack_top.*, stack_top.* - n);\n" ++
                "    stack_top.* += 1;\n" ++
                "}}\n", .{n});
            defer allocator.free(jit_logic);
            try new_content.appendSlice(allocator, jit_logic);
            try dir.writeFile(.{ .sub_path = entry.name, .data = new_content.items });
            std.debug.print("Patched {s}\n", .{entry.name});
        } else if (std.mem.startsWith(u8, entry.name, "swap") and std.mem.endsWith(u8, entry.name, ".zig")) {
            const num_str = entry.name[4 .. entry.name.len - 4];
            const n = std.fmt.parseInt(u64, num_str, 10) catch continue;

            const content = try dir.readFileAlloc(allocator, entry.name, 10 * 1024);
            defer allocator.free(content);
            if (std.mem.indexOf(u8, content, "pub fn jit_compile") != null) continue;

            var new_content = std.ArrayListUnmanaged(u8){};
            defer new_content.deinit(allocator);
            try new_content.appendSlice(allocator, content);

            const jit_logic = try std.fmt.allocPrint(allocator, "\npub fn jit_compile(jit: anytype, pc: *usize, stack_top: *u64, bytecode: []const u8) !void {{\n" ++
                "    _ = pc; _ = bytecode;\n" ++
                "    const n = {d};\n" ++
                "    if (stack_top.* < n + 1) return error.StackUnderflow;\n" ++
                "    try jit.compile_swap(stack_top.* - 1, stack_top.* - 1 - n);\n" ++
                "}}\n", .{n});
            defer allocator.free(jit_logic);
            try new_content.appendSlice(allocator, jit_logic);
            try dir.writeFile(.{ .sub_path = entry.name, .data = new_content.items });
            std.debug.print("Patched {s}\n", .{entry.name});
        }
    }
}
