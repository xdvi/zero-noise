const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const risk = @import("../risk.zig");
const blast = @import("../../analysis/blast.zig");
const runner = @import("../../mutation/runner.zig");
const deps_mod = @import("../deps.zig");
const ledger_mod = @import("../../storage/ledger.zig");

const ToolResult = common.ToolResult;

const Args = struct {
    filepath: []const u8 = "",
    format: []const u8 = "text",
    expected_hash: ?[]const u8 = null,
    test_cmd: ?[]const u8 = null,
    root: []const u8 = ".",
    max_blast_risk: ?[]const u8 = null,
    patch_file: ?[]const u8 = null,
    candidate_content: ?[]const u8 = null,
    force: bool = false,
    fix: bool = true,
};

fn parseArgs(args: ?std.json.Value) Args {
    var force: bool = false;
    var fix: bool = true;
    if (args) |v| {
        if (v == .object) {
            if (v.object.get("force")) |val| {
                if (val == .bool) force = val.bool;
            }
            if (v.object.get("fix")) |val| {
                if (val == .bool) fix = val.bool;
            }
        }
    }
    return .{
        .filepath = common.getStringArg(args, "filepath") orelse "",
        .format = common.getStringArg(args, "format") orelse "text",
        .expected_hash = common.getStringArg(args, "expected_hash"),
        .test_cmd = common.getStringArg(args, "test_cmd"),
        .root = common.getStringArg(args, "root") orelse ".",
        .max_blast_risk = common.getStringArg(args, "max_blast_risk"),
        .patch_file = common.getStringArg(args, "patch_file"),
        .candidate_content = common.getStringArg(args, "candidate_content"),
        .force = force,
        .fix = fix,
    };
}

pub fn executeSafeRefactorWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const filepath = parsed.filepath;
    const format = parsed.format;
    const expected_hash = parsed.expected_hash;
    const test_cmd = parsed.test_cmd;
    const root = parsed.root;
    const max_blast_risk_str = parsed.max_blast_risk;
    const patch_file = parsed.patch_file;
    const candidate_content = parsed.candidate_content;
    var target_patch: ?[]const u8 = null;
    defer if (target_patch) |tp| allocator.free(tp);

    if (patch_file) |pf| {
        if (!(runner.checkWorkspaceConfinement(allocator, pf) catch false)) {
            const text = try std.fmt.allocPrint(allocator, "Error: patch file is outside workspace: {s}", .{pf});
            return ToolResult{ .text = text, .is_error = true };
        }
        target_patch = deps.fs.readFileAlloc(allocator, pf) catch null;
    }

    var maybe_db = deps.db.open(allocator, root) catch null;
    defer if (maybe_db) |*db| db.close();

    var maybe_ledger: ?ledger_mod.RefactorLedger = if (maybe_db) |db|
        ledger_mod.RefactorLedger.init(db, allocator)
    else
        null;

    var task_id: ?[]const u8 = null;
    defer if (task_id) |tid| allocator.free(tid);

    if (maybe_ledger) |*ledger| {
        task_id = ledger.createTask(filepath, expected_hash orelse "unlocked", 0, 0) catch null;
    }

    const force = parsed.force;
    const fix = parsed.fix;

    // Enforcement of max_blast_risk
    if (max_blast_risk_str) |mbr| {
        if (!force) {
            const allowed_opt: ?blast.RiskLevel = if (std.mem.eql(u8, mbr, "low"))
                .low
            else if (std.mem.eql(u8, mbr, "medium"))
                .medium
            else if (std.mem.eql(u8, mbr, "high"))
                .high
            else
                null;

            if (allowed_opt) |allowed| {
                const target_content = deps.fs.readFileAlloc(allocator, filepath) catch null;
                defer if (target_content) |tc| allocator.free(tc);

                if (target_content) |tc| {
                    const actual_risk = risk.computeFileBlastRisk(allocator, filepath, tc, root, deps);
                    const risk_val: u8 = switch (actual_risk) {
                        .low => 1,
                        .medium => 2,
                        .high => 3,
                    };
                    const allowed_val: u8 = switch (allowed) {
                        .low => 1,
                        .medium => 2,
                        .high => 3,
                    };

                    if (risk_val > allowed_val) {
                        if (maybe_ledger) |*ledger| {
                            if (task_id) |tid| {
                                ledger.updateTaskStatus(tid, "aborted") catch {};
                            }
                        }
                        const err_msg = try std.fmt.allocPrint(
                            allocator,
                            "Blast radius risk '{s}' exceeds maximum allowed risk '{s}' (use force=true to override)",
                            .{ actual_risk.asString(), mbr },
                        );
                        defer allocator.free(err_msg);

                        if (compact.isCompact(format)) {
                            const text = try compact.formatRefactor(allocator, filepath, "aborted", expected_hash orelse "unlocked", err_msg);
                            return ToolResult{ .text = text, .is_error = true };
                        }

                        if (std.mem.eql(u8, format, "json")) {
                            var buf: std.ArrayList(u8) = .empty;
                            defer buf.deinit(allocator);
                            try buf.appendSlice(allocator, "{\"filepath\":");
                            try common.appendJsonEscaped(&buf, allocator, filepath);
                            try buf.appendSlice(allocator, ",\"status\":\"aborted\",\"diff\":\"\",\"error\":");
                            try common.appendJsonEscaped(&buf, allocator, err_msg);
                            try buf.append(allocator, '}');
                            return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = true };
                        }

                        const text = try std.fmt.allocPrint(allocator, "Safe Refactor ({s}): status aborted\nError: {s}\n", .{ filepath, err_msg });
                        return ToolResult{ .text = text, .is_error = true };
                    }
                }
            }
        }
    }

    var simplified_from_deps: ?[]u8 = null;
    defer if (simplified_from_deps) |sc| allocator.free(sc);

    if (candidate_content == null and patch_file == null and target_patch == null) {
        if (deps.fs.readFileAlloc(allocator, filepath)) |original_content| {
            defer allocator.free(original_content);
            if (deps.simplify(allocator, original_content)) |simplified_content| {
                simplified_from_deps = simplified_content;
            } else |_| {}
        } else |_| {}
    }

    const effective_candidate = if (candidate_content) |cc| cc else simplified_from_deps;

    var result = runner.executeSafeRefactor(allocator, .{
        .filepath = filepath,
        .hash = .{ .expected_hash = expected_hash },
        .test_run = .{ .test_cmd = test_cmd },
        .fix = fix,
        .patch = .{
            .candidate_content = effective_candidate,
            .patch_file = patch_file,
            .patch_content = target_patch,
        },
    }) catch |err| {
        if (maybe_ledger) |*ledger| {
            if (task_id) |tid| {
                ledger.updateTaskStatus(tid, "aborted") catch {};
            }
        }
        const text = try std.fmt.allocPrint(allocator, "Safe refactor error: {s}", .{@errorName(err)});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer result.deinit(allocator);

    const status_str = result.status.asString();

    if (maybe_ledger) |*ledger| {
        if (task_id) |tid| {
            ledger.updateTaskStatus(tid, status_str) catch {};
        }
    }

    if (compact.isCompact(format)) {
        const text = try compact.formatRefactor(allocator, filepath, status_str, expected_hash orelse "unlocked", if (result.error_msg) |em| em else "safe refactor completed");
        return ToolResult{ .text = text, .is_error = (result.status == .aborted or result.status == .rolled_back) };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"filepath\":");
        try common.appendJsonEscaped(&buf, allocator, filepath);
        try buf.print(allocator, ",\"status\":\"{s}\",\"diff\":", .{status_str});
        try common.appendJsonEscaped(&buf, allocator, result.diff);
        if (result.error_msg) |em| {
            try buf.appendSlice(allocator, ",\"error\":");
            try common.appendJsonEscaped(&buf, allocator, em);
        }
        try buf.append(allocator, '}');
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = (result.status == .aborted or result.status == .rolled_back) };
    }

    if (result.error_msg) |em| {
        const text = try std.fmt.allocPrint(allocator, "Safe Refactor ({s}): status {s}\nError: {s}\n", .{ filepath, status_str, em });
        return ToolResult{ .text = text, .is_error = true };
    }

    const text = try std.fmt.allocPrint(allocator, "Safe Refactor: {s} verified and applied successfully (hash: {s}).\n{s}", .{ filepath, expected_hash orelse "unlocked", result.diff });
    return ToolResult{ .text = text, .is_error = false };
}

pub fn executeSafeRefactor(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeSafeRefactorWithDeps(allocator, args, &default);
}
