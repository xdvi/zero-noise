const std = @import("std");
const refactor_tool = @import("../mcp/tools/safe_refactor.zig");
const deps_mod = @import("../mcp/deps.zig");

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
    const parsed = parseRefactorArgs(args);
    const file = parsed.file orelse return 1;

    const default_deps = deps_mod.defaultDeps();
    const res = try refactor_tool.executeSafeRefactorDirect(allocator, .{
        .filepath = file,
        .format = parsed.format,
        .fix = parsed.fix,
        .expected_hash = parsed.expected_hash,
        .test_cmd = parsed.test_cmd,
    }, &default_deps);
    defer res.deinit(allocator);

    try out_list.appendSlice(allocator, res.text);
    if (res.text.len > 0 and res.text[res.text.len - 1] != '\n') {
        try out_list.append(allocator, '\n');
    }

    return if (res.is_error) 1 else 0;
}

const RefactorArgs = struct {
    format: []const u8 = "text",
    file: ?[]const u8 = null,
    fix: bool = false,
    expected_hash: ?[]const u8 = null,
    test_cmd: ?[]const u8 = null,
};

fn parseRefactorArgs(args: []const []const u8) RefactorArgs {
    var parsed = RefactorArgs{};
    for (args) |arg| {
        applyRefactorArg(&parsed, arg);
    }
    return parsed;
}

fn applyRefactorArg(parsed: *RefactorArgs, arg: []const u8) void {
    if (std.mem.startsWith(u8, arg, "--format=")) {
        parsed.format = arg["--format=".len..];
    } else if (std.mem.startsWith(u8, arg, "--expected-hash=")) {
        parsed.expected_hash = arg["--expected-hash=".len..];
    } else if (std.mem.startsWith(u8, arg, "--test-cmd=")) {
        parsed.test_cmd = arg["--test-cmd=".len..];
    } else if (std.mem.eql(u8, arg, "--fix")) {
        parsed.fix = true;
    } else if (std.mem.eql(u8, arg, "--dry-run")) {
        parsed.fix = false;
    } else if (!std.mem.startsWith(u8, arg, "-")) {
        if (parsed.file == null) parsed.file = arg;
    }
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
