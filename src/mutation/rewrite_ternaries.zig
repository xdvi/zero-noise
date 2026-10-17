const std = @import("std");
const common = @import("rewrite_common.zig");
const isIdentChar = common.isIdentChar;
const skipWhitespace = common.skipWhitespace;
const matchKeyword = common.matchKeyword;
const skipTriviaOrLiteral = common.skipTriviaOrLiteral;
const isCSharp = common.isCSharp;
const isAlreadyBoolean = common.isAlreadyBoolean;
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

        if (source[i] == '?' and (i + 1 >= source.len or (source[i + 1] != '.' and source[i + 1] != '?'))) {
            const after_q = skipWhitespace(source, i + 1);
            var is_consequent_true = false;
            var is_consequent_false = false;
            var kw_len: usize = 0;

            if (matchKeyword(source, after_q, "true") or matchKeyword(source, after_q, "True")) {
                is_consequent_true = true;
                kw_len = 4;
            } else if (matchKeyword(source, after_q, "false") or matchKeyword(source, after_q, "False")) {
                is_consequent_false = true;
                kw_len = 5;
            }

            if (is_consequent_true or is_consequent_false) {
                const after_cons = skipWhitespace(source, after_q + kw_len);
                if (after_cons < source.len and source[after_cons] == ':') {
                    const after_colon = skipWhitespace(source, after_cons + 1);
                    var is_alt_true = false;
                    var is_alt_false = false;
                    var alt_kw_len: usize = 0;

                    if (matchKeyword(source, after_colon, "true") or matchKeyword(source, after_colon, "True")) {
                        is_alt_true = true;
                        alt_kw_len = 4;
                    } else if (matchKeyword(source, after_colon, "false") or matchKeyword(source, after_colon, "False")) {
                        is_alt_false = true;
                        alt_kw_len = 5;
                    }

                    if ((is_consequent_true and is_alt_false) or (is_consequent_false and is_alt_true)) {
                        const cond_start = findConditionStart(source, i);
                        const cond_end = findConditionEnd(source, cond_start, i);
                        const raw_cond = source[cond_start..cond_end];
                        const cond = std.mem.trim(u8, raw_cond, " \t\r\n");

                        if (cond.len > 0) {
                            const bytes_to_discard = i - cond_start;
                            if (out.items.len >= bytes_to_discard) {
                                out.shrinkRetainingCapacity(out.items.len - bytes_to_discard);
                            }

                            if (out.items.len > 0 and (out.items[out.items.len - 1] != ' ' and out.items[out.items.len - 1] != '\t' and out.items[out.items.len - 1] != '(' and out.items[out.items.len - 1] != '\n')) {
                                try out.append(allocator, ' ');
                            }

                            if (is_consequent_true and is_alt_false) {
                                if (isCSharp(source) or isAlreadyBoolean(cond)) {
                                    try out.appendSlice(allocator, cond);
                                } else {
                                    try out.appendSlice(allocator, "Boolean(");
                                    try out.appendSlice(allocator, cond);
                                    try out.append(allocator, ')');
                                }
                            } else {
                                const inverted = try invertCondition(allocator, cond);
                                defer allocator.free(inverted);
                                try out.appendSlice(allocator, inverted);
                            }

                            i = after_colon + alt_kw_len;
                            changes += 1;
                            continue;
                        }
                    }
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

