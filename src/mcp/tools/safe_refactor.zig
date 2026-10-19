const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const risk = @import("../risk.zig");
const blast = @import("../../analysis/blast.zig");
const runner = @import("../../mutation/runner.zig");
const deps_mod = @import("../deps.zig");
const ledger_mod = @import("../../storage/ledger.zig");
const db_mod = @import("../../storage/db.zig");

const ToolResult = common.ToolResult;

pub const SafeRefactorParams = struct {
    filepath: []const u8 = "",
    format: []const u8 = "text",
    expected_hash: ?[]const u8 = null,
    test_cmd: ?[]const u8 = null,
    root: []const u8 = ".",
    max_blast_risk: ?[]const u8 = null,
    patch_file: ?[]const u8 = null,
    patch_content: ?[]const u8 = null,
    patch_kind: ?[]const u8 = null,
    candidate_content: ?[]const u8 = null,
    force: bool = false,
    fix: bool = false,
};

const Args = SafeRefactorParams;

fn parseArgs(args: ?std.json.Value) SafeRefactorParams {
    return .{
        .filepath = common.getStringArg(args, "filepath") orelse "",
        .format = common.getStringArg(args, "format") orelse "text",
        .expected_hash = common.getStringArg(args, "expected_hash"),
        .test_cmd = common.getStringArg(args, "test_cmd"),
        .root = common.getStringArg(args, "root") orelse ".",
        .max_blast_risk = common.getStringArg(args, "max_blast_risk"),
        .patch_file = common.getStringArg(args, "patch_file"),
        .patch_content = common.getStringArg(args, "patch_content"),
        .patch_kind = common.getStringArg(args, "patch_kind"),
        .candidate_content = common.getStringArg(args, "candidate_content"),
        .force = common.getBoolArg(args, "force", false),
        .fix = common.getBoolArg(args, "fix", false),
    };
}

pub fn executeSafeRefactorDirect(allocator: std.mem.Allocator, params: SafeRefactorParams, deps: *const deps_mod.Deps) !ToolResult {
    const filepath = params.filepath;
    const format = params.format;
    const expected_hash = params.expected_hash;
    const test_cmd = params.test_cmd;
    const root = params.root;
    const max_blast_risk_str = params.max_blast_risk;
    const patch_file = params.patch_file;
    const patch_content = params.patch_content;
    const patch_kind = params.patch_kind;
    const candidate_content = params.candidate_content;
    var target_patch: ?[]const u8 = null;
    defer if (target_patch) |tp| allocator.free(tp);

    target_patch = loadPatchFile(allocator, deps, patch_file) catch |err| {
        if (err == error.PatchOutsideWorkspace) {
            const text = try std.fmt.allocPrint(allocator, "Error: patch file is outside workspace: {s}", .{patch_file.?});
            return ToolResult{ .text = text, .is_error = true };
        }
        return err;
    };

    const setup = try prepareSafeRefactorSetup(allocator, deps, params, filepath, root, expected_hash);
    defer if (setup.task_id) |tid| allocator.free(tid);
    defer if (setup.maybe_db) |db_ptr| {
        db_ptr.close();
        allocator.destroy(db_ptr);
    };

    const force = setup.force;
    const fix = setup.fix;
    const maybe_ledger = setup.maybe_ledger;
    const task_id = setup.task_id;

    // Enforcement of max_blast_risk
    const blast_check = try enforceBlastRisk(allocator, filepath, root, max_blast_risk_str, force, deps, maybe_ledger, task_id, format, expected_hash);
    if (blast_check) |blocked| {
        return blocked;
    }

    const simplified_from_deps = prepareCandidate(allocator, deps, filepath, candidate_content, patch_content, patch_file, target_patch);
    defer if (simplified_from_deps) |sc| allocator.free(sc);

    const effective_candidate = if (candidate_content) |cc| cc else simplified_from_deps;
    const effective_patch = patch_content orelse target_patch;

    return runSafeRefactorAndFormat(
        allocator,
        filepath,
        format,
        expected_hash,
        test_cmd,
        fix,
        patch_file,
        effective_patch,
        patch_kind,
        effective_candidate,
        maybe_ledger,
        task_id,
    );
}

pub fn executeSafeRefactorWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    return executeSafeRefactorDirect(allocator, parsed, deps);
}

fn formatSafeRefactorResult(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    format: []const u8,
    status_str: []const u8,
    result: runner.SafeRefactorResult,
    expected_hash: ?[]const u8,
) !ToolResult {
    if (compact.isCompact(format)) {
        const text = try compact.formatRefactor(allocator, filepath, status_str, expected_hash orelse "unlocked", if (result.error_msg) |em| em else "safe refactor completed");
        return ToolResult{ .text = text, .is_error = (result.status == .aborted or result.status == .rolled_back) };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"filepath\":");
        try common.appendJsonEscaped(&buf, allocator, filepath);
        try buf.print(allocator, ",\"status\":\"{s}\"", .{status_str});
        if (result.classification) |classification| {
            try buf.print(allocator, ",\"classification\":\"{s}\"", .{classification.asString()});
        }
        try buf.appendSlice(allocator, ",\"diff\":");
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

    if (result.status == .dry_run) {
        const text = try std.fmt.allocPrint(allocator, "Safe Refactor ({s}): dry run only, no changes applied (hash: {s}).\n{s}", .{ filepath, expected_hash orelse "unlocked", result.diff });
        return ToolResult{ .text = text, .is_error = false };
    }

    const text = try std.fmt.allocPrint(allocator, "Safe Refactor: {s} verified and applied successfully (hash: {s}).\n{s}", .{ filepath, expected_hash orelse "unlocked", result.diff });
    return ToolResult{ .text = text, .is_error = false };
}

pub fn executeSafeRefactor(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeSafeRefactorWithDeps(allocator, args, &default);
}

fn enforceBlastRisk(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    root: []const u8,
    mbr: ?[]const u8,
    force: bool,
    deps: *const deps_mod.Deps,
    maybe_ledger: ?ledger_mod.RefactorLedger,
    task_id: ?[]const u8,
    format: []const u8,
    expected_hash: ?[]const u8,
) !?ToolResult {
    if (force) return null;
    const mbr_str = mbr orelse return null;
    const allowed_level = parseRiskLevel(mbr_str) orelse return null;

    const target_content = deps.fs.readFileAlloc(allocator, filepath) catch return null;
    defer allocator.free(target_content);

    const actual_risk = risk.computeFileBlastRisk(allocator, filepath, target_content, root, deps);
    const risk_val: u8 = switch (actual_risk) {
        .low => 1,
        .medium => 2,
        .high => 3,
    };
    const allowed_val: u8 = switch (allowed_level) {
        .low => 1,
        .medium => 2,
        .high => 3,
    };

    if (risk_val <= allowed_val) return null;

    if (maybe_ledger) |ledger| {
        var l = ledger;
        if (task_id) |tid| {
            l.updateTaskStatus(tid, "aborted") catch {};
        }
    }

    const err_msg = try std.fmt.allocPrint(
        allocator,
        "Blast radius risk '{s}' exceeds maximum allowed risk '{s}' (use force=true to override)",
        .{ actual_risk.asString(), mbr_str },
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

fn parseRiskLevel(s: []const u8) ?blast.RiskLevel {
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    if (std.mem.eql(u8, s, "high")) return .high;
    return null;
}

const SafeRefactorSetup = struct {
    target_patch: ?[]u8,
    maybe_db: ?*db_mod.Database,
    maybe_ledger: ?ledger_mod.RefactorLedger,
    task_id: ?[]const u8,
    force: bool,
    fix: bool,
};

fn loadPatchFile(allocator: std.mem.Allocator, deps: *const deps_mod.Deps, patch_file: ?[]const u8) !?[]u8 {
    const pf = patch_file orelse return null;
    if (!(runner.checkWorkspaceConfinement(allocator, pf) catch false)) return error.PatchOutsideWorkspace;
    return deps.fs.readFileAlloc(allocator, pf) catch null;
}

fn prepareSafeRefactorSetup(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    parsed: Args,
    filepath: []const u8,
    root: []const u8,
    expected_hash: ?[]const u8,
) !SafeRefactorSetup {
    var maybe_db_ptr: ?*db_mod.Database = null;
    var maybe_ledger: ?ledger_mod.RefactorLedger = null;
    var task_id: ?[]const u8 = null;
    if (deps.db.open(allocator, root)) |db_val| {
        const db_ptr = allocator.create(db_mod.Database) catch null;
        if (db_ptr) |ptr| {
            ptr.* = db_val;
            maybe_db_ptr = ptr;
            maybe_ledger = ledger_mod.RefactorLedger.init(ptr, allocator);
            if (maybe_ledger) |*ledger| {
                task_id = ledger.createTask(filepath, expected_hash orelse "unlocked", 0, 0) catch null;
            }
        }
    } else |_| {}

    return SafeRefactorSetup{
        .target_patch = null,
        .maybe_db = maybe_db_ptr,
        .maybe_ledger = maybe_ledger,
        .task_id = task_id,
        .force = parsed.force,
        .fix = parsed.fix,
    };
}

fn runSafeRefactorAndFormat(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    format: []const u8,
    expected_hash: ?[]const u8,
    test_cmd: ?[]const u8,
    fix: bool,
    patch_file: ?[]const u8,
    patch_content: ?[]const u8,
    patch_kind: ?[]const u8,
    effective_candidate: ?[]const u8,
    maybe_ledger: ?ledger_mod.RefactorLedger,
    task_id: ?[]const u8,
) !ToolResult {
    var ledger = maybe_ledger;
    var result = runner.executeSafeRefactor(allocator, .{
        .filepath = filepath,
        .hash = .{ .expected_hash = expected_hash },
        .test_run = .{ .test_cmd = test_cmd },
        .fix = fix,
        .patch = .{
            .candidate_content = effective_candidate,
            .patch_file = patch_file,
            .patch_content = patch_content,
            .patch_kind = patch_kind,
        },
    }) catch |err| {
        if (ledger) |*l| {
            if (task_id) |tid| {
                l.updateTaskStatus(tid, "aborted") catch {};
            }
        }
        const text = try std.fmt.allocPrint(allocator, "Safe refactor error: {s}", .{@errorName(err)});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer result.deinit(allocator);

    const status_str = result.status.asString();
    updateLedgerStatus(ledger, task_id, status_str);
    return formatSafeRefactorResult(allocator, filepath, format, status_str, result, expected_hash);
}

fn prepareCandidate(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    filepath: []const u8,
    candidate_content: ?[]const u8,
    patch_content: ?[]const u8,
    patch_file: ?[]const u8,
    target_patch: ?[]const u8,
) ?[]u8 {
    if (candidate_content != null or patch_content != null or patch_file != null or target_patch != null) return null;
    const original_content = deps.fs.readFileAlloc(allocator, filepath) catch return null;
    defer allocator.free(original_content);
    return deps.simplify(allocator, original_content) catch null;
}

fn updateLedgerStatus(ledger: ?ledger_mod.RefactorLedger, task_id: ?[]const u8, status: []const u8) void {
    if (ledger) |l| {
        var ll = l;
        if (task_id) |tid| {
            ll.updateTaskStatus(tid, status) catch {};
        }
    }
}

test "mcp safe_refactor fix defaults to dry-run" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const tmp_path = "tests/.test_mcp_fix_default.ts";
    try runner.writeFile(tmp_path, "const ok = valid ? true : false;\n");
    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db") catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db-wal") catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db-shm") catch {};
        std.Io.Dir.cwd().deleteDir(io, "tests/.zero-noise") catch {};
    }

    const args_json = "{\"filepath\":\"" ++ tmp_path ++ "\",\"root\":\"tests\",\"format\":\"json\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();

    const default = deps_mod.defaultDeps();
    const res = try executeSafeRefactorWithDeps(allocator, parsed.value, &default);
    defer res.deinit(allocator);

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "\"status\":\"dry_run\"") != null);

    const read_back = try runner.readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings("const ok = valid ? true : false;\n", read_back);
}
