const std = @import("std");
const complexity_tool = @import("../mcp/tools/complexity.zig");
const deps_mod = @import("../mcp/deps.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, io: std.Io, stdout: std.Io.File, stderr: std.Io.File) !u8 {
    _ = stderr;
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeComplexity(allocator, args, &out_list);
    try stdout.writeStreamingAll(io, out_list.items);
    return code;
}

pub fn executeComplexity(allocator: std.mem.Allocator, args: []const []const u8, out_list: *std.ArrayList(u8)) !u8 {
    var format: []const u8 = "text";
    var threshold: i64 = 15;
    var paths_list: std.ArrayList([]const u8) = .empty;
    defer paths_list.deinit(allocator);

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--threshold=")) {
            const th_str = arg["--threshold=".len..];
            threshold = std.fmt.parseInt(i64, th_str, 10) catch 15;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths_list.append(allocator, arg);
        }
    }

    if (paths_list.items.len == 0) {
        try paths_list.append(allocator, ".");
    }

    const default_deps = deps_mod.defaultDeps();
    const th_u32: u32 = if (threshold < 0) 15 else @intCast(@min(threshold, std.math.maxInt(u32)));
    var exceeded_count: usize = 0;
    for (paths_list.items) |path| {
        const res = try complexity_tool.executeComplexityDirect(allocator, .{
            .path = path,
            .threshold = th_u32,
            .format = format,
        }, &default_deps);
        defer res.deinit(allocator);

        try out_list.appendSlice(allocator, res.text);
        if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
            try out_list.append(allocator, '\n');
        }
        if (res.is_error) exceeded_count += 1;
        exceeded_count += res.count;
    }

    return if (exceeded_count > 0) 1 else 0;
}

test "complexity cli execution exceeding threshold returns exit code 1" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_python.py", "--threshold=5", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeComplexity(allocator, &args, &out_list);
    try std.testing.expectEqual(1, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "[COMPLEXITY]") != null);
}

test "complexity cli execution within threshold returns exit code 0" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_python.py", "--threshold=100", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeComplexity(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "0 (threshold: 100)") != null);
}
