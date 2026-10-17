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

pub fn rewriteDoubleNegation(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
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

        if (tryUnwrapDoubleNegationParen(source, i, &out, allocator)) |next_i| {
            i = next_i;
            changes += 1;
            continue;
        }

        if (source[i] == '!' and i + 1 < source.len and source[i + 1] == '!') {
            const next_char = if (i + 2 < source.len) source[i + 2] else 0;
            if (next_char != '=') {
                i += 2;
                changes += 1;
                continue;
            }
        }

        try out.append(allocator, source[i]);
        i += 1;
    }

    return RewriteResult{
        .output = try out.toOwnedSlice(allocator),
        .changes_count = changes,
    };
}

fn tryUnwrapDoubleNegationParen(
    source: []const u8,
    i: usize,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ?usize {
    if (!(source[i] == '!' and i + 1 < source.len and source[i + 1] == '(')) return null;
    const after_open = skipWhitespace(source, i + 2);
    if (!(after_open < source.len and source[after_open] == '!')) return null;
    const next_char = if (after_open + 1 < source.len) source[after_open + 1] else 0;
    if (next_char == '=') return null;
    const operand_start = after_open + 1;
    const close_idx = findMatchingParen(source, i + 1) orelse return null;
    if (close_idx <= operand_start) return null;
    const raw_inner = source[operand_start..close_idx];
    const inner = std.mem.trim(u8, raw_inner, " \t\r\n");
    out.appendSlice(allocator, inner) catch return null;
    return close_idx + 1;
}
