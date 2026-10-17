const std = @import("std");
const blast_tool = @import("../mcp/tools/blast_radius.zig");
const deps_mod = @import("../mcp/deps.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, io: std.Io, stdout: std.Io.File, stderr: std.Io.File) !u8 {
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeBlast(allocator, args, &out_list);
    if (code != 0 and out_list.items.len == 0) {
        try stderr.writeStreamingAll(io, "Error: zero-noise blast requires a <symbol> argument.\nUsage: zero-noise blast <symbol> [--root=.] [--format=text|json|compact]\n");
        return code;
    }
    try stdout.writeStreamingAll(io, out_list.items);
    return code;
}

pub fn executeBlast(allocator: std.mem.Allocator, args: []const []const u8, out_list: *std.ArrayList(u8)) !u8 {
    var format: []const u8 = "text";
    var root: []const u8 = ".";
    var symbol_opt: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            root = arg["--root=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (symbol_opt == null) {
                symbol_opt = arg;
            }
        }
    }

    const symbol = symbol_opt orelse return 1;

    const default_deps = deps_mod.defaultDeps();
    const res = try blast_tool.executeBlastRadiusDirect(allocator, .{
        .symbol = symbol,
        .root = root,
        .format = format,
    }, &default_deps);
    defer res.deinit(allocator);

    try out_list.appendSlice(allocator, res.text);
    if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
        try out_list.append(allocator, '\n');
    }

    return if (res.is_error) 1 else 0;
}

test "blast cli execution" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "handleSession", "--root=tests/fixtures", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeBlast(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "[BLAST]") != null);

    const err_args = [_][]const u8{};
    const err_code = try executeBlast(allocator, &err_args, &out_list);
    try std.testing.expectEqual(1, err_code);
}
