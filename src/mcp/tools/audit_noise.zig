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
        if (deps.fs.readFileAlloc(allocator, cfg_path)) |cfg_content| {
            defer allocator.free(cfg_content);
            if (std.json.parseFromSlice(std.json.Value, allocator, cfg_content, .{})) |parsed_cfg| {
                defer parsed_cfg.deinit();
                if (parsed_cfg.value == .object) {
                    if (parsed_cfg.value.object.get("max_nesting")) |v| {
                        if (v == .integer and v.integer >= 0) {
                            noise_cfg.max_nesting = @intCast(v.integer);
                        }
                    }
                    if (parsed_cfg.value.object.get("max_closure_len")) |v| {
                        if (v == .integer and v.integer >= 0) {
                            noise_cfg.max_closure_len = @intCast(v.integer);
                        }
                    }
                    if (parsed_cfg.value.object.get("ignore_patterns")) |v| {
                        if (v == .array) {
                            for (v.array.items) |item| {
                                if (item == .string) {
                                    try ignore_patterns.append(allocator, try allocator.dupe(u8, item.string));
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        } else |_| {}
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
        var ignored = false;
        for (ignore_patterns.items) |pat| {
            if (std.mem.indexOf(u8, file_path, pat) != null) {
                ignored = true;
                break;
            }
        }
        if (ignored) continue;

        const lang = grammars.Language.fromPath(file_path);
        if (lang == .unknown) continue;

        const content = deps.fs.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        const findings = deps.auditNoiseWithOptions(allocator, content, lang, noise_cfg) catch continue;
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

    return fmt.auditNoise(allocator, path, all_findings, format);
}

pub fn executeAuditNoise(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeAuditNoiseWithDeps(allocator, args, &default);
}
