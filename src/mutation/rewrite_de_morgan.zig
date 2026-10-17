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

pub fn rewriteDeMorgan(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
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

        if (source[i] == '!' and i + 1 < source.len and source[i + 1] == '(') {
            const close_idx = findMatchingParen(source, i + 1);
            if (close_idx) |c_idx| {
                const inner = source[i + 2 .. c_idx];
                if (try parseDeMorganInner(allocator, inner)) |dm| {
                    defer allocator.free(dm);

                    const should_wrap = shouldWrapDeMorgan(source, i, c_idx + 1);
                    if (should_wrap) {
                        try out.append(allocator, '(');
                        try out.appendSlice(allocator, dm);
                        try out.append(allocator, ')');
                    } else {
                        try out.appendSlice(allocator, dm);
                    }

                    i = c_idx + 1;
                    changes += 1;
                    continue;
                }
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
