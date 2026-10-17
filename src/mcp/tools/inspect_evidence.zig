const std = @import("std");
const common = @import("../common.zig");
const noise = @import("../../analysis/noise.zig");
const complexity = @import("../../analysis/complexity.zig");
const deps_mod = @import("../deps.zig");
const grammars = @import("../../treesitter/grammars.zig");
const risk = @import("../risk.zig");
const blast = @import("../../analysis/blast.zig");

const ToolResult = common.ToolResult;

const Args = struct {
    path: []const u8 = "",
    root: []const u8 = ".",
    page: u32 = 1,
    page_size: u32 = 10,
};

fn parseArgs(args: ?std.json.Value) Args {
    return .{
        .path = common.getStringArg(args, "path") orelse (common.getStringArg(args, "filepath") orelse ""),
        .root = common.getStringArg(args, "root") orelse ".",
        .page = common.getU32Arg(args, "page", 1),
        .page_size = common.getU32Arg(args, "page_size", 10),
    };
}

pub fn executeInspectEvidenceWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const path = parsed.path;
    if (path.len == 0) {
        return ToolResult{ .text = try allocator.dupe(u8, "Error: path argument is required"), .is_error = true };
    }

    const content = deps.fs.readFileAlloc(allocator, path) catch {
        const text = try std.fmt.allocPrint(allocator, "Error: target file not found: {s}", .{path});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer allocator.free(content);

    const root = parsed.root;
    const page_raw = parsed.page;
    const page: u32 = if (page_raw == 0) 1 else page_raw;
    const page_size_raw = parsed.page_size;
    const page_size: u32 = if (page_size_raw == 0) 10 else page_size_raw;

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const actual_hash = std.fmt.bytesToHex(digest, .lower);

    const lang = grammars.Language.fromPath(path);
    var findings: []noise.NoiseFinding = &.{};
    if (lang != .unknown) {
        findings = deps.auditNoiseWithOptions(allocator, content, lang, .{}) catch &.{};
    }
    defer if (findings.len > 0) noise.deinitFindings(allocator, findings);

    const max_complexity = computeMaxComplexity(allocator, deps, content, lang);
    const blast_risk = risk.computeFileBlastRisk(allocator, path, content, root, deps);
    const total_findings = findings.len;
    const priority_score = computePriorityScore(blast_risk, max_complexity, total_findings);

    const start_idx: usize = @min(@as(usize, page - 1) * @as(usize, page_size), total_findings);
    const end_idx: usize = @min(start_idx + @as(usize, page_size), total_findings);
    const page_findings = findings[start_idx..end_idx];

    const text = try buildInspectEvidenceJson(allocator, path, actual_hash, total_findings, max_complexity, blast_risk, priority_score, page, page_size, page_findings);

    if (deps.db.open(allocator, root)) |db_inst| {
        var db = db_inst;
        defer db.close();
        db.recordFileCacheSlice(allocator, path, 0, @intCast(content.len), &actual_hash, @intCast(total_findings), @intCast(max_complexity)) catch {};
    } else |_| {}

    return ToolResult{ .text = text, .is_error = false };
}

pub fn executeInspectEvidence(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeInspectEvidenceWithDeps(allocator, args, &default);
}

fn computeMaxComplexity(allocator: std.mem.Allocator, deps: *const deps_mod.Deps, content: []const u8, lang: grammars.Language) u32 {
    if (lang == .unknown) return 0;
    const records_opt = deps.calculateComplexity(allocator, content, lang) catch null;
    defer if (records_opt) |recs| { for (recs) |r| r.deinit(allocator); allocator.free(recs); };
    var max: u32 = 0;
    if (records_opt) |recs| {
        for (recs) |r| {
            if (r.complexity > max) max = r.complexity;
        }
    }
    return max;
}

fn computePriorityScore(blast_risk: blast.RiskLevel, max_complexity: u32, total_findings: usize) u32 {
    const base = max_complexity * 2 + @as(u32, @intCast(total_findings)) * 3;
    return switch (blast_risk) {
        .low => base,
        .medium => base / 2,
        .high => base / 4,
    };
}

fn buildInspectEvidenceJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual_hash: [64]u8,
    total_findings: usize,
    max_complexity: u32,
    blast_risk: blast.RiskLevel,
    priority_score: u32,
    page: u32,
    page_size: u32,
    page_findings: []noise.NoiseFinding,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"file\":");
    try common.appendJsonEscaped(&buf, allocator, path);
    try buf.print(allocator, ",\"state_lock_sha256\":\"{s}\",\"metrics\":{{\"noise_count\":{d},\"cognitive_complexity\":{d},\"blast_radius_risk\":", .{
        actual_hash, total_findings, max_complexity,
    });
    try common.appendJsonEscaped(&buf, allocator, blast_risk.asString());
    try buf.print(allocator, ",\"priority_score\":{d}", .{priority_score});
    try buf.appendSlice(allocator, "},\"findings\":[");
    for (page_findings, 0..) |f, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"rule\":");
        try common.appendJsonEscaped(&buf, allocator, f.rule.asString());
        try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{
            f.line, f.column,
        });
        try common.appendJsonEscaped(&buf, allocator, f.message);
        try buf.append(allocator, '}');
    }
    try buf.print(allocator, "],\"page\":{d},\"page_size\":{d},\"total\":{d}}}", .{ page, page_size, total_findings });
    return buf.toOwnedSlice(allocator);
}
