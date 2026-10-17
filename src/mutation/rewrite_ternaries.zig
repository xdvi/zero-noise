const std = @import("std");
const common = @import("rewrite_common.zig");
const isIdentChar = common.isIdentChar;
const skipWhitespace = common.skipWhitespace;
const matchKeyword = common.matchKeyword;
const skipTriviaOrLiteral = common.skipTriviaOrLiteral;

const findConditionStart = common.findConditionStart;
const findConditionEnd = common.findConditionEnd;
const invertCondition = common.invertCondition;
const findMatchingParen = common.findMatchingParen;
const parseDeMorganInner = common.parseDeMorganInner;
const shouldWrapDeMorgan = common.shouldWrapDeMorgan;
const isOperatorChar = common.isOperatorChar;

pub const RewriteResult = common.RewriteResult;

pub fn rewriteTernaries(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var changes: usize = 0;

    while (i < source.len) {
        if (skipTriviaOrLiteral(source, i)) |next_i| {
            try out.appendSlice(allocator, source[i..next_i]);
            i = next_i;
            continue;
        }

        if (simplifyTernaryAt(source, i, &out, allocator)) |next_i| {
            i = next_i;
            changes += 1;
            continue;
        }

        try out.append(allocator, source[i]);
        i += 1;
    }

    return RewriteResult{
        .output = try out.toOwnedSlice(allocator),
        .changes_count = changes,
    };
}

fn simplifyTernaryAt(
    source: []const u8,
    i: usize,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ?usize {
    if (!(source[i] == '?' and (i + 1 >= source.len or (source[i + 1] != '.' and source[i + 1] != '?')))) return null;

    const after_q = skipWhitespace(source, i + 1);
    const cons = keywordInfo(source, after_q) orelse return null;
    const after_cons = skipWhitespace(source, after_q + cons.len);
    if (!(after_cons < source.len and source[after_cons] == ':')) return null;

    const after_colon = skipWhitespace(source, after_cons + 1);
    const alt = keywordInfo(source, after_colon) orelse return null;

    if (!((cons.value and !alt.value) or (!cons.value and alt.value))) return null;

    const cond_start = findConditionStart(source, i);
    const cond_end = findConditionEnd(source, cond_start, i);
    const raw_cond = source[cond_start..cond_end];
    const cond = std.mem.trim(u8, raw_cond, " \t\r\n");
    if (cond.len == 0) return null;

    discardConditionPrefix(out, i - cond_start);

    if (out.items.len > 0 and !isSpacingBoundary(out.items[out.items.len - 1])) {
        out.append(allocator, ' ') catch return null;
    }

    appendTernaryResult(out, allocator, cond, cons.value and !alt.value) catch return null;

    return after_colon + alt.len;
}

const KeywordInfo = struct { value: bool, len: usize };

fn keywordInfo(source: []const u8, idx: usize) ?KeywordInfo {
    if (matchKeyword(source, idx, "true") or matchKeyword(source, idx, "True")) return .{ .value = true, .len = 4 };
    if (matchKeyword(source, idx, "false") or matchKeyword(source, idx, "False")) return .{ .value = false, .len = 5 };
    return null;
}

fn isSpacingBoundary(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '(' or ch == '\n';
}

fn discardConditionPrefix(out: *std.ArrayList(u8), bytes_to_discard: usize) void {
    if (out.items.len >= bytes_to_discard) {
        out.shrinkRetainingCapacity(out.items.len - bytes_to_discard);
    }
}

fn appendTernaryResult(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cond: []const u8, keep_cond: bool) !void {
    if (keep_cond) {
        try out.appendSlice(allocator, cond);
        return;
    }
    const inverted = try invertCondition(allocator, cond);
    defer allocator.free(inverted);
    try out.appendSlice(allocator, inverted);
}
