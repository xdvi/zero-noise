const std = @import("std");
const audit_tool = @import("../mcp/tools/audit_noise.zig");
const deps_mod = @import("../mcp/deps.zig");

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

    const default_deps = deps_mod.defaultDeps();
    var total_findings: usize = 0;

    for (paths_list.items) |path| {
        const res = if (std.mem.eql(u8, format, "evidence")) blk: {
            var map: std.json.ObjectMap = .empty;
            defer map.deinit(allocator);
            try map.put(allocator, "path", .{ .string = path });
            try map.put(allocator, "format", .{ .string = format });
            break :blk try audit_tool.executeAuditNoiseWithDeps(allocator, .{ .object = map }, &default_deps);
        } else blk: {
            break :blk try audit_tool.executeAuditNoiseDirect(allocator, .{
                .path = path,
                .format = format,
            }, &default_deps);
        };
        defer res.deinit(allocator);

        try out_list.appendSlice(allocator, res.text);
        if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
            try out_list.append(allocator, '\n');
        }
        if (res.is_error) {
            total_findings += 1;
        }
        total_findings += res.count;
    }

    return if (total_findings > 0) 1 else 0;
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

test "audit cli format=evidence outputs evidence contract json" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_typescript.ts", "--format=evidence" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    _ = try executeAudit(allocator, &args, &out_list);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "state_lock_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "blast_radius_risk") != null);
}
