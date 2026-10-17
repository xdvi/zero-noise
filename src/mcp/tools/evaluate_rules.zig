const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const fmt = @import("../format.zig");
const noise = @import("../../analysis/noise.zig");
const grammars = @import("../../treesitter/grammars.zig");
const deps_mod = @import("../deps.zig");
const audit_noise = @import("audit_noise.zig");

const ToolResult = common.ToolResult;

pub const CustomRuleFinding = struct {
    file: []const u8,
    rule: []const u8,
    line: u32,
    column: u32,
    message: []const u8,

    pub fn deinit(self: CustomRuleFinding, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.rule);
        allocator.free(self.message);
    }
};

pub fn isRegexMeta(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '.', '*', '+', '?', '^', '$', '|', '\\' => true,
        else => false,
    };
}

pub fn matchesPattern(line: []const u8, pattern: []const u8) ?usize {
    if (pattern.len == 0 or line.len == 0) return null;

    var clean_buf: [256]u8 = undefined;
    const needle = if (pattern.len < clean_buf.len) blk: {
        var clean_len: usize = 0;
        var i: usize = 0;
        while (i < pattern.len) {
            if (pattern[i] == '\\' and i + 1 < pattern.len and isRegexMeta(pattern[i + 1])) {
                clean_buf[clean_len] = pattern[i + 1];
                clean_len += 1;
                i += 2;
            } else {
                clean_buf[clean_len] = pattern[i];
                clean_len += 1;
                i += 1;
            }
        }
        break :blk clean_buf[0..clean_len];
    } else pattern;

    var in_sq = false;
    var in_dq = false;
    var in_bt = false;
    var in_block = false;

    var i: usize = 0;
    while (i < line.len) {
        if (!in_sq and !in_dq and !in_bt and !in_block) {
            if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                break;
            }
            if (line[i] == '#') {
                break;
            }
            if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                in_block = true;
                i += 2;
                continue;
            }
            if (line[i] == '"') {
                in_dq = true;
                i += 1;
                continue;
            }
            if (line[i] == '\'') {
                in_sq = true;
                i += 1;
                continue;
            }
            if (line[i] == '`') {
                in_bt = true;
                i += 1;
                continue;
            }

            if (needle.len > 0 and std.mem.startsWith(u8, line[i..], needle)) {
                return i;
            }
            if (std.mem.startsWith(u8, line[i..], pattern)) {
                return i;
            }

            i += 1;
            continue;
        }

        if (in_block) {
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                in_block = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        if (in_dq) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 2;
                continue;
            }
            if (line[i] == '"') {
                in_dq = false;
            }
            i += 1;
            continue;
        }

        if (in_sq) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 2;
                continue;
            }
            if (line[i] == '\'') {
                in_sq = false;
            }
            i += 1;
            continue;
        }

        if (in_bt) {
            if (line[i] == '`') {
                in_bt = false;
            }
            i += 1;
            continue;
        }
    }

    return null;
}

const Args = struct {
    rules: ?[]const u8 = null,
    path: []const u8 = ".",
    format: []const u8 = "text",
};

fn parseArgs(args: ?std.json.Value) Args {
    return .{
        .rules = common.getStringArg(args, "rules"),
        .path = common.getStringArg(args, "path") orelse ".",
        .format = common.getStringArg(args, "format") orelse "text",
    };
}

pub fn executeEvaluateRulesWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const rules_path = parsed.rules;
    if (rules_path == null) {
        return audit_noise.executeAuditNoiseWithDeps(allocator, args, deps);
    }

    const path = parsed.path;
    const format = parsed.format;

    const rules_file_path = rules_path.?;
    const rules_content = deps.fs.readFileAlloc(allocator, rules_file_path) catch {
        const text = try std.fmt.allocPrint(allocator, "Error: rules file not found: {s}", .{rules_file_path});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer allocator.free(rules_content);

    var parsed_rules = std.json.parseFromSlice(std.json.Value, allocator, rules_content, .{}) catch {
        const text = try std.fmt.allocPrint(allocator, "Error: failed to parse rules JSON from {s}", .{rules_file_path});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer parsed_rules.deinit();

    const rules_array: []const std.json.Value = switch (parsed_rules.value) {
        .array => |arr| arr.items,
        .object => |obj| if (obj.get("rules")) |r| (if (r == .array) r.array.items else &.{}) else &.{},
        else => &.{},
    };

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try common.collectSourceFiles(allocator, path, &files_list);

    var all_findings: std.ArrayList(CustomRuleFinding) = .empty;
    defer {
        for (all_findings.items) |item| item.deinit(allocator);
        all_findings.deinit(allocator);
    }

    for (files_list.items) |file_path| {
        const content = deps.fs.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        for (rules_array) |rule_val| {
            if (rule_val != .object) continue;
            const robj = rule_val.object;

            if (robj.get("languages")) |langs_val| {
                if (langs_val == .array) {
                    var matches_lang = false;
                    for (langs_val.array.items) |l_item| {
                        if (l_item == .string) {
                            const filter_lang = grammars.Language.fromName(l_item.string);
                            if (filter_lang != .unknown) {
                                if (filter_lang == grammars.Language.fromPath(file_path)) {
                                    matches_lang = true;
                                    break;
                                }
                            } else if (std.mem.endsWith(u8, file_path, l_item.string)) {
                                matches_lang = true;
                                break;
                            }
                        }
                    }
                    if (!matches_lang) continue;
                }
            }

            const rule_id = if (robj.get("id")) |id_v| (if (id_v == .string) id_v.string else "custom-rule") else "custom-rule";
            const rule_pattern = if (robj.get("pattern")) |p_v| (if (p_v == .string) p_v.string else "") else "";
            if (rule_pattern.len == 0) continue;
            const rule_msg = if (robj.get("message")) |m_v| (if (m_v == .string) m_v.string else "Custom rule violation") else "Custom rule violation";

            var line_no: u32 = 1;
            var line_start: usize = 0;
            var i: usize = 0;
            while (i <= content.len) : (i += 1) {
                if (i == content.len or content[i] == '\n') {
                    const line = content[line_start..i];
                    if (matchesPattern(line, rule_pattern)) |match_idx| {
                        try all_findings.append(allocator, .{
                            .file = try allocator.dupe(u8, file_path),
                            .rule = try allocator.dupe(u8, rule_id),
                            .line = line_no,
                            .column = @intCast(match_idx + 1),
                            .message = try allocator.dupe(u8, rule_msg),
                        });
                    }
                    line_no += 1;
                    line_start = i + 1;
                }
            }
        }
    }

    return fmt.evaluateRules(allocator, path, all_findings, format);
}

pub fn executeEvaluateRules(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeEvaluateRulesWithDeps(allocator, args, &default);
}
