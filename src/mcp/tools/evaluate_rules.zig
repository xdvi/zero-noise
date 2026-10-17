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

    var state = PatternScanState{};
    var i: usize = 0;
    while (i < line.len) {
        const step = advancePatternState(line, i, needle, pattern, state);
        if (step.matched) return step.match_index;
        if (step.stop) break;
        i = step.next_i;
        state = step.state;
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
        try evaluateRulesForFile(allocator, file_path, content, rules_array, &all_findings);
    }

    return fmt.evaluateRules(allocator, path, all_findings, format);
}

pub fn executeEvaluateRules(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeEvaluateRulesWithDeps(allocator, args, &default);
}

fn evaluateRulesForFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    rules_array: []const std.json.Value,
    all_findings: *std.ArrayList(CustomRuleFinding),
) !void {
    for (rules_array) |rule_val| {
        if (rule_val != .object) continue;
        const robj = rule_val.object;

        if (!languageMatches(robj, file_path)) continue;

        const rule_id = stringField(robj, "id", "custom-rule");
        const rule_pattern = stringField(robj, "pattern", "");
        if (rule_pattern.len == 0) continue;
        const rule_msg = stringField(robj, "message", "Custom rule violation");

        try appendRuleMatches(allocator, file_path, content, rule_id, rule_pattern, rule_msg, all_findings);
    }
}

fn languageMatches(robj: std.json.ObjectMap, file_path: []const u8) bool {
    const langs_val = robj.get("languages") orelse return true;
    if (langs_val != .array) return true;
    for (langs_val.array.items) |l_item| {
        if (l_item != .string) continue;
        const filter_lang = grammars.Language.fromName(l_item.string);
        if (filter_lang != .unknown) {
            if (filter_lang == grammars.Language.fromPath(file_path)) return true;
        } else if (std.mem.endsWith(u8, file_path, l_item.string)) {
            return true;
        }
    }
    return false;
}

fn appendRuleMatches(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    rule_id: []const u8,
    rule_pattern: []const u8,
    rule_msg: []const u8,
    all_findings: *std.ArrayList(CustomRuleFinding),
) !void {
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

fn stringField(robj: std.json.ObjectMap, key: []const u8, default_val: []const u8) []const u8 {
    const v = robj.get(key) orelse return default_val;
    if (v != .string) return default_val;
    return v.string;
}


const PatternScanState = struct {
    in_sq: bool = false,
    in_dq: bool = false,
    in_bt: bool = false,
    in_block: bool = false,
};

const PatternStep = struct {
    next_i: usize,
    state: PatternScanState,
    matched: bool = false,
    match_index: usize = 0,
    stop: bool = false,
};

fn advancePatternState(line: []const u8, i: usize, needle: []const u8, pattern: []const u8, state: PatternScanState) PatternStep {
    var s = state;
    if (!s.in_sq and !s.in_dq and !s.in_bt and !s.in_block) {
        return advanceNormalState(line, i, needle, pattern, &s);
    }
    if (s.in_block) return advanceBlockState(line, i, &s);
    if (s.in_dq) return advanceDoubleQuoteState(line, i, &s);
    if (s.in_sq) return advanceSingleQuoteState(line, i, &s);
    if (s.in_bt) return advanceBacktickState(line, i, &s);
    return .{ .next_i = i + 1, .state = s };
}

fn advanceNormalState(line: []const u8, i: usize, needle: []const u8, pattern: []const u8, s: *PatternScanState) PatternStep {
    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
        return .{ .next_i = i, .state = s.*, .stop = true };
    }
    if (line[i] == '#') {
        return .{ .next_i = i, .state = s.*, .stop = true };
    }
    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
        s.in_block = true;
        return .{ .next_i = i + 2, .state = s.* };
    }
    if (line[i] == '"') {
        s.in_dq = true;
        return .{ .next_i = i + 1, .state = s.* };
    }
    if (line[i] == '\'') {
        s.in_sq = true;
        return .{ .next_i = i + 1, .state = s.* };
    }
    if (line[i] == '`') {
        s.in_bt = true;
        return .{ .next_i = i + 1, .state = s.* };
    }
    if (needle.len > 0 and std.mem.startsWith(u8, line[i..], needle)) {
        return .{ .next_i = i, .state = s.*, .matched = true, .match_index = i };
    }
    if (std.mem.startsWith(u8, line[i..], pattern)) {
        return .{ .next_i = i, .state = s.*, .matched = true, .match_index = i };
    }
    return .{ .next_i = i + 1, .state = s.* };
}

fn advanceBlockState(line: []const u8, i: usize, s: *PatternScanState) PatternStep {
    if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
        s.in_block = false;
        return .{ .next_i = i + 2, .state = s.* };
    }
    return .{ .next_i = i + 1, .state = s.* };
}

fn advanceDoubleQuoteState(line: []const u8, i: usize, s: *PatternScanState) PatternStep {
    if (line[i] == '\\' and i + 1 < line.len) {
        return .{ .next_i = i + 2, .state = s.* };
    }
    if (line[i] == '"') s.in_dq = false;
    return .{ .next_i = i + 1, .state = s.* };
}

fn advanceSingleQuoteState(line: []const u8, i: usize, s: *PatternScanState) PatternStep {
    if (line[i] == '\\' and i + 1 < line.len) {
        return .{ .next_i = i + 2, .state = s.* };
    }
    if (line[i] == '\'') s.in_sq = false;
    return .{ .next_i = i + 1, .state = s.* };
}

fn advanceBacktickState(line: []const u8, i: usize, s: *PatternScanState) PatternStep {
    if (line[i] == '`') s.in_bt = false;
    return .{ .next_i = i + 1, .state = s.* };
}
