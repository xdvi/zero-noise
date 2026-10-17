const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const fmt = @import("../format.zig");
const risk = @import("../risk.zig");
const noise = @import("../../analysis/noise.zig");
const complexity = @import("../../analysis/complexity.zig");
const blast = @import("../../analysis/blast.zig");
const deps_mod = @import("../deps.zig");
const rewriter = @import("../../mutation/rewriter.zig");
const grammars = @import("../../treesitter/grammars.zig");
const db_mod = @import("../../storage/db.zig");
const ledger_mod = @import("../../storage/ledger.zig");
const inspect_evidence = @import("inspect_evidence.zig");

const ToolResult = common.ToolResult;

pub const FindingItem = struct {
    file: []const u8,
    rule: noise.NoiseRule,
    line: u32,
    column: u32,
    message: []const u8,

    pub fn deinit(self: FindingItem, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.message);
    }
};

const Args = struct {
    format: []const u8 = "text",
    path: []const u8 = ".",
    config: ?[]const u8 = null,
};

fn parseArgs(args: ?std.json.Value) Args {
    return .{
        .format = common.getStringArg(args, "format") orelse "text",
        .path = common.getStringArg(args, "path") orelse ".",
        .config = common.getStringArg(args, "config"),
    };
}

pub fn executeAuditNoiseWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const format = parsed.format;
    if (std.mem.eql(u8, format, "evidence")) {
        return inspect_evidence.executeInspectEvidenceWithDeps(allocator, args, deps);
    }

    const path = parsed.path;

    var noise_cfg = noise.NoiseConfig{};
    var ignore_patterns: std.ArrayList([]const u8) = .empty;
    defer {
        for (ignore_patterns.items) |pat| allocator.free(pat);
        ignore_patterns.deinit(allocator);
    }

    if (parsed.config) |cfg_path| {
        loadNoiseConfig(allocator, deps, cfg_path, &noise_cfg, &ignore_patterns);
    }

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try common.collectSourceFiles(allocator, path, &files_list);

    var all_findings: std.ArrayList(FindingItem) = .empty;
    defer {
        for (all_findings.items) |item| item.deinit(allocator);
        all_findings.deinit(allocator);
    }

    for (files_list.items) |file_path| {
        try auditOneFile(allocator, deps, file_path, noise_cfg, &ignore_patterns, &all_findings);
    }

    return fmt.auditNoise(allocator, path, all_findings, format);
}

pub fn executeAuditNoise(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeAuditNoiseWithDeps(allocator, args, &default);
}

fn auditOneFile(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    file_path: []const u8,
    noise_cfg: noise.NoiseConfig,
    ignore_patterns: *std.ArrayList([]const u8),
    all_findings: *std.ArrayList(FindingItem),
) !void {
    for (ignore_patterns.items) |pat| {
        if (matchGlob(pat, file_path)) return;
    }

    const lang = grammars.Language.fromPath(file_path);
    if (lang == .unknown) return;

    const content = deps.fs.readFileAlloc(allocator, file_path) catch return;
    defer allocator.free(content);

    const findings = deps.auditNoiseWithOptions(allocator, content, lang, noise_cfg) catch return;
    defer noise.deinitFindings(allocator, findings);

    for (findings) |f| {
        try all_findings.append(allocator, .{
            .file = try allocator.dupe(u8, file_path),
            .rule = f.rule,
            .line = f.line,
            .column = f.column,
            .message = try allocator.dupe(u8, f.message),
        });
    }
}

fn loadNoiseConfig(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    cfg_path: []const u8,
    noise_cfg: *noise.NoiseConfig,
    ignore_patterns: *std.ArrayList([]const u8),
) void {
    const cfg_content = deps.fs.readFileAlloc(allocator, cfg_path) catch return;
    defer allocator.free(cfg_content);

    const parsed_cfg = std.json.parseFromSlice(std.json.Value, allocator, cfg_content, .{}) catch return;
    defer parsed_cfg.deinit();

    if (parsed_cfg.value != .object) return;
    const obj = parsed_cfg.value.object;

    applyNoiseScalar(obj, "max_nesting", &noise_cfg.max_nesting);
    applyNoiseScalar(obj, "max_closure_len", &noise_cfg.max_closure_len);
    appendIgnorePatterns(allocator, obj, ignore_patterns);
}

fn applyNoiseScalar(obj: std.json.ObjectMap, key: []const u8, target: *u32) void {
    const v = obj.get(key) orelse return;
    if (v != .integer) return;
    if (v.integer < 0) return;
    target.* = @intCast(v.integer);
}

fn appendIgnorePatterns(allocator: std.mem.Allocator, obj: std.json.ObjectMap, ignore_patterns: *std.ArrayList([]const u8)) void {
    const v = obj.get("ignore_patterns") orelse return;
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item != .string) continue;
        const duped = allocator.dupe(u8, item.string) catch continue;
        ignore_patterns.append(allocator, duped) catch allocator.free(duped);
    }
}

fn matchGlob(pattern: []const u8, text: []const u8) bool {
    // Simple wildcard matcher supporting '*' and '?'.
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;
    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}
