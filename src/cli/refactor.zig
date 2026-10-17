const std = @import("std");
const server = @import("../mcp/server.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, io: std.Io, stdout: std.Io.File, stderr: std.Io.File) !u8 {
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeRefactor(allocator, args, &out_list);
    if (code != 0 and out_list.items.len == 0) {
        try stderr.writeStreamingAll(io, "Error: zero-noise refactor requires a <file> argument.\nUsage: zero-noise refactor <file> [--fix] [--dry-run] [--expected-hash=<hash>] [--format=text|json|compact]\n");
        return code;
    }
    try stdout.writeStreamingAll(io, out_list.items);
    return code;
}

pub fn executeRefactor(allocator: std.mem.Allocator, args: []const []const u8, out_list: *std.ArrayList(u8)) !u8 {
    var format: []const u8 = "text";
    var file_opt: ?[]const u8 = null;
    var fix = false;
    var expected_hash: ?[]const u8 = null;
    var test_cmd: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--expected-hash=")) {
            expected_hash = arg["--expected-hash=".len..];
        } else if (std.mem.startsWith(u8, arg, "--test-cmd=")) {
            test_cmd = arg["--test-cmd=".len..];
        } else if (std.mem.eql(u8, arg, "--fix")) {
            fix = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            fix = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (file_opt == null) {
                file_opt = arg;
            }
        }
    }

    const file = file_opt orelse return 1;

    var json_args = std.json.Value{
        .object = .empty,
    };
    defer json_args.object.deinit(allocator);

    try json_args.object.put(allocator, "filepath", std.json.Value{ .string = file });
    try json_args.object.put(allocator, "fix", std.json.Value{ .bool = fix });
    try json_args.object.put(allocator, "format", std.json.Value{ .string = format });
    if (expected_hash) |eh| {
        try json_args.object.put(allocator, "expected_hash", std.json.Value{ .string = eh });
    }
    if (test_cmd) |tc| {
        try json_args.object.put(allocator, "test_cmd", std.json.Value{ .string = tc });
    }


    const res = try server.executeToolCall(allocator, "safe_refactor", json_args);
    defer res.deinit(allocator);

    try out_list.appendSlice(allocator, res.text);
    if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
        try out_list.append(allocator, '\n');
    }

    return if (res.is_error) 1 else 0;
}

test "refactor cli execution" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_typescript.ts", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeRefactor(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "[REFACTOR]") != null);

    const err_args = [_][]const u8{};
    const err_code = try executeRefactor(allocator, &err_args, &out_list);
    try std.testing.expectEqual(1, err_code);
}

test "refactor cli dry-run flag support" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "tests/fixtures/dirty/noisy_typescript.ts", "--dry-run", "--format=compact" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executeRefactor(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "status=dry_run") != null);

    // Verify --dry-run overrides --fix when passed after
    var out_list2: std.ArrayList(u8) = .empty;
    defer out_list2.deinit(allocator);
    const args2 = [_][]const u8{ "tests/fixtures/dirty/noisy_typescript.ts", "--fix", "--dry-run", "--format=compact" };
    const code2 = try executeRefactor(allocator, &args2, &out_list2);
    try std.testing.expectEqual(0, code2);
    try std.testing.expect(std.mem.indexOf(u8, out_list2.items, "status=dry_run") != null);
}

