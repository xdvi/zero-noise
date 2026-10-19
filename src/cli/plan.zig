const std = @import("std");
const common = @import("../mcp/common.zig");
const propose_fixes = @import("../mcp/tools/propose_fixes.zig");
const deps_mod = @import("../mcp/deps.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, io: std.Io, stdout: std.Io.File, stderr: std.Io.File) !u8 {
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executePlan(allocator, args, &out_list);
    if (code != 0 and out_list.items.len == 0) {
        try stderr.writeStreamingAll(io, "Error: zero-noise plan requires a <path> argument.\nUsage: zero-noise plan <path> [--kinds=guard,constant] [--include-patches] [--compose] [--out=<file>] [--page=N] [--page-size=N] [--format=text|json|compact] [--root=PATH]\n");
        return code;
    }
    try stdout.writeStreamingAll(io, out_list.items);
    return code;
}

pub fn executePlan(allocator: std.mem.Allocator, args: []const []const u8, out_list: *std.ArrayList(u8)) !u8 {
    const parsed = parsePlanArgs(args);
    const path = parsed.path orelse return 1;

    if (!pathExists(path)) {
        const message = try std.fmt.allocPrint(allocator, "Error: path not found: {s}\n", .{path});
        defer allocator.free(message);
        try out_list.appendSlice(allocator, message);
        return 1;
    }

    const default_deps = deps_mod.defaultDeps();
    var report = propose_fixes.collectProposalReport(allocator, .{
        .path = path,
        .kinds = parsed.kinds,
        .include_patches = parsed.include_patches,
        .compose = parsed.compose,
        .page = parsed.page,
        .page_size = parsed.page_size,
        .root = parsed.root,
        .format = parsed.format,
    }, &default_deps) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Error: plan failed: {s}\n", .{@errorName(err)});
        defer allocator.free(message);
        try out_list.appendSlice(allocator, message);
        return 1;
    };
    defer report.deinit(allocator);

    if (parsed.compose) {
        return try writeComposed(allocator, &report, parsed.out, out_list);
    }

    const text = try propose_fixes.formatProposalReport(allocator, &report, parsed.format);
    defer allocator.free(text);
    try out_list.appendSlice(allocator, text);
    return 0;
}

fn writeComposed(
    allocator: std.mem.Allocator,
    report: *const propose_fixes.ProposalReport,
    out_path: ?[]const u8,
    out_list: *std.ArrayList(u8),
) !u8 {
    const composed = report.composed orelse {
        try out_list.appendSlice(allocator, "composed: skipped (a single file path is required)\n");
        return 0;
    };

    if (out_path) |path| {
        const io = std.Options.debug_io;
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
            const message = try std.fmt.allocPrint(allocator, "Error: cannot write composed patch: {s}\n", .{path});
            defer allocator.free(message);
            try out_list.appendSlice(allocator, message);
            return 1;
        };
        try file.writeStreamingAll(io, composed.patch);
        file.close(io);
    } else {
        try out_list.appendSlice(allocator, composed.patch);
        if (composed.patch.len > 0 and composed.patch[composed.patch.len - 1] != '\n') {
            try out_list.append(allocator, '\n');
        }
    }

    try out_list.print(allocator, "composed: applied={d} conflicts={d}\n", .{
        composed.applied.len,
        composed.conflicts.len,
    });
    return 0;
}

const PlanArgs = struct {
    path: ?[]const u8 = null,
    kinds: ?[]const u8 = null,
    include_patches: bool = false,
    compose: bool = false,
    out: ?[]const u8 = null,
    page: u32 = 1,
    page_size: u32 = 10,
    format: []const u8 = "text",
    root: []const u8 = ".",
};

fn parsePlanArgs(args: []const []const u8) PlanArgs {
    var parsed = PlanArgs{};
    for (args) |arg| {
        applyPlanArg(&parsed, arg);
    }
    return parsed;
}

fn applyPlanArg(parsed: *PlanArgs, arg: []const u8) void {
    if (std.mem.startsWith(u8, arg, "--format=")) {
        parsed.format = arg["--format=".len..];
    } else if (std.mem.startsWith(u8, arg, "--kinds=")) {
        parsed.kinds = arg["--kinds=".len..];
    } else if (std.mem.startsWith(u8, arg, "--out=")) {
        parsed.out = arg["--out=".len..];
    } else if (std.mem.startsWith(u8, arg, "--page=")) {
        parsed.page = std.fmt.parseInt(u32, arg["--page=".len..], 10) catch parsed.page;
    } else if (std.mem.startsWith(u8, arg, "--page-size=")) {
        parsed.page_size = std.fmt.parseInt(u32, arg["--page-size=".len..], 10) catch parsed.page_size;
    } else if (std.mem.startsWith(u8, arg, "--root=")) {
        parsed.root = arg["--root=".len..];
    } else if (std.mem.eql(u8, arg, "--include-patches")) {
        parsed.include_patches = true;
    } else if (std.mem.eql(u8, arg, "--compose")) {
        parsed.compose = true;
    } else if (!std.mem.startsWith(u8, arg, "-")) {
        if (parsed.path == null) parsed.path = arg;
    }
}

fn pathExists(path: []const u8) bool {
    const io = std.Options.debug_io;
    if (common.openAnyFile(io, path, .{})) |file| {
        file.close(io);
        return true;
    } else |_| {}

    if (common.openAnyDir(io, path, .{})) |*opened| {
        var dir = opened.*;
        dir.close(io);
        return true;
    } else |_| {}

    return false;
}

const GUARD_FIXTURE = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";

const TWO_GUARD_FIXTURE =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    sendEmail(user);
    \\  }
    \\}
    \\function notify(user: User): void {
    \\  if (user.hasPaid) {
    \\    sendInvoice(user);
    \\  }
    \\}
    \\
;

const OVERLAP_FIXTURE =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    log("a");
    \\    log("a");
    \\    log("a");
    \\  }
    \\}
    \\
;

fn writeTestFile(path: []const u8, content: []const u8) !void {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    try file.writeStreamingAll(io, content);
    file.close(io);
}

fn deleteTestFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};
}

test "plan cli lists proposals and exits 0" {
    const allocator = std.testing.allocator;
    const path = "tests/test_plan_cli.ts";
    try writeTestFile(path, GUARD_FIXTURE);
    defer deleteTestFile(path);

    const args = [_][]const u8{path};
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executePlan(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "[FIX]") != null);
}

test "plan cli without path exits 1" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{};
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executePlan(allocator, &args, &out_list);
    try std.testing.expectEqual(1, code);
}

test "plan cli format=json parses" {
    const allocator = std.testing.allocator;
    const path = "tests/test_plan_cli_json.ts";
    try writeTestFile(path, GUARD_FIXTURE);
    defer deleteTestFile(path);

    const args = [_][]const u8{ path, "--format=json" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executePlan(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out_list.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("total").?.integer);
    try std.testing.expectEqualStrings("guard", parsed.value.object.get("proposals").?.array.items[0].object.get("kind").?.string);
}

test "plan cli compose prints both proposals and a summary" {
    const allocator = std.testing.allocator;
    const path = "tests/test_plan_cli_compose.ts";
    try writeTestFile(path, TWO_GUARD_FIXTURE);
    defer deleteTestFile(path);

    const args = [_][]const u8{ path, "--compose" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executePlan(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "-  if (user.isActive) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "-  if (user.hasPaid) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "composed: applied=2 conflicts=0") != null);
}

test "plan cli compose reports conflicts" {
    const allocator = std.testing.allocator;
    const path = "tests/test_plan_cli_conflict.ts";
    try writeTestFile(path, OVERLAP_FIXTURE);
    defer deleteTestFile(path);

    const args = [_][]const u8{ path, "--compose" };
    var out_list: std.ArrayList(u8) = .empty;
    defer out_list.deinit(allocator);

    const code = try executePlan(allocator, &args, &out_list);
    try std.testing.expectEqual(0, code);
    try std.testing.expect(std.mem.indexOf(u8, out_list.items, "conflicts=1") != null);
}
