const std = @import("std");
const server = @import("../mcp/server.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, io: std.Io, stdout: std.Io.File) !u8 {
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

    var total_exit: u8 = 0;
    for (paths_list.items) |path| {
        var json_args = std.json.Value{
            .object = .empty,
        };
        defer json_args.object.deinit(allocator);

        try json_args.object.put(allocator, "path", std.json.Value{ .string = path });
        try json_args.object.put(allocator, "threshold", std.json.Value{ .integer = threshold });
        try json_args.object.put(allocator, "format", std.json.Value{ .string = format });


        const res = try server.executeToolCall(allocator, "complexity", json_args);
        defer res.deinit(allocator);

        try out_list.appendSlice(allocator, res.text);
        if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
            try out_list.append(allocator, '\n');
        }
        if (res.is_error) total_exit = 1;
    }

    return total_exit;
}

test "complexity cli execution" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_python.py", "--threshold=5", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeComplexity(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "[COMPLEXITY]") != null);
}

