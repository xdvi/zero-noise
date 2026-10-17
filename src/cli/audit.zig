const std = @import("std");
const app = @import("../mcp/app.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, io: std.Io, stdout: std.Io.File, stderr: std.Io.File) !u8 {
    _ = stderr;
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeAudit(allocator, args, &out_list);
    try stdout.writeStreamingAll(io, out_list.items);
    return code;
}

pub fn executeAudit(allocator: std.mem.Allocator, args: []const []const u8, out_list: *std.ArrayList(u8)) !u8 {
    var format: []const u8 = "text";
    var paths_list: std.ArrayList([]const u8) = .empty;
    defer paths_list.deinit(allocator);

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths_list.append(allocator, arg);
        }
    }

    if (paths_list.items.len == 0) {
        try paths_list.append(allocator, ".");
    }

    var total_exit: u8 = 0;
    var all_findings: std.ArrayList(usize) = .empty;
    defer all_findings.deinit(allocator);

    for (paths_list.items) |path| {
        var json_args = std.json.Value{
            .object = .empty,
        };
        defer json_args.object.deinit(allocator);

        try json_args.object.put(allocator, "path", std.json.Value{ .string = path });
        try json_args.object.put(allocator, "format", std.json.Value{ .string = format });


        const res = try app.executeToolCall(allocator, "audit_noise", json_args);
        defer res.deinit(allocator);

        try out_list.appendSlice(allocator, res.text);
        if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
            try out_list.append(allocator, '\n');
        }
        if (res.is_error) {
            try all_findings.append(allocator, 1);
        }
        if (res.count > 0) {
            try all_findings.appendNTimes(allocator, 1, res.count);
        }
    }

    total_exit = if (all_findings.items.len > 0) 1 else 0;
    return total_exit;
}

test "audit cli option parsing with violations returns exit code 1" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_typescript.ts", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeAudit(allocator, &args, &out_list);
    try std.testing.expectEqual(1, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "[NOISE]") != null);
}

test "audit cli clean path returns exit code 0" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/clean/clean_typescript.ts", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeAudit(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "0 structural noise violations detected.") != null);
}

