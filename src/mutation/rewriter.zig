const std = @import("std");

pub const RewriteResult = struct {
    output: []u8,
    changes_count: usize,

    pub fn deinit(self: *RewriteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn simplify(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const res = try rewrite(allocator, source);
    return res.output;
}

pub fn rewrite(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);

    var total_changes: usize = 0;
    var pass: usize = 0;

    while (pass < 10) : (pass += 1) {
        var changed_in_pass = false;

        const ternary_res = try rewriteTernaries(allocator, current);
        if (ternary_res.changes_count > 0) {
            allocator.free(current);
            current = ternary_res.output;
            total_changes += ternary_res.changes_count;
            changed_in_pass = true;
        } else {
            allocator.free(ternary_res.output);
        }

        const de_morgan_res = try rewriteDeMorgan(allocator, current);
        if (de_morgan_res.changes_count > 0) {
            allocator.free(current);
            current = de_morgan_res.output;
            total_changes += de_morgan_res.changes_count;
            changed_in_pass = true;
        } else {
            allocator.free(de_morgan_res.output);
        }

        const double_neg_res = try rewriteDoubleNegation(allocator, current);
        if (double_neg_res.changes_count > 0) {
            allocator.free(current);
            current = double_neg_res.output;
            total_changes += double_neg_res.changes_count;
            changed_in_pass = true;
        } else {
            allocator.free(double_neg_res.output);
        }

        if (!changed_in_pass) break;
    }

    return RewriteResult{
        .output = current,
        .changes_count = total_changes,
    };
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

fn skipWhitespace(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) : (i += 1) {}
    return i;
}

fn matchKeyword(src: []const u8, idx: usize, kw: []const u8) bool {
    if (idx + kw.len > src.len) return false;
    if (!std.mem.eql(u8, src[idx .. idx + kw.len], kw)) return false;
    if (idx + kw.len < src.len and isIdentChar(src[idx + kw.len])) return false;
    return true;
}

pub fn rewriteTernaries(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var changes: usize = 0;

    while (i < source.len) {
        if (source[i] == '"' or source[i] == '\'') {
            const quote = source[i];
            try out.append(allocator, quote);
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    try out.append(allocator, source[i]);
                    try out.append(allocator, source[i + 1]);
                    i += 2;
                } else {
                    try out.append(allocator, source[i]);
                    i += 1;
                }
            }
            if (i < source.len) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '`') {
            try out.append(allocator, '`');
            i += 1;
            while (i < source.len and source[i] != '`') {
                if (source[i] == '\\' and i + 1 < source.len) {
                    try out.append(allocator, source[i]);
                    try out.append(allocator, source[i + 1]);
                    i += 2;
                } else {
                    try out.append(allocator, source[i]);
                    i += 1;
                }
            }
            if (i < source.len) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.append(allocator, '/');
            try out.append(allocator, '*');
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            if (i + 1 < source.len) {
                try out.append(allocator, '*');
                try out.append(allocator, '/');
                i += 2;
            }
            continue;
        }

        if (source[i] == '#') {
            while (i < source.len and source[i] != '\n') {
                try out.append(allocator, source[i]);
                i += 1;
            }
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
                                try out.appendSlice(allocator, cond);
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

fn findConditionStart(src: []const u8, q_idx: usize) usize {
    var idx = q_idx;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;

    while (idx > 0) {
        idx -= 1;
        const ch = src[idx];

        if (ch == ')') {
            paren_depth += 1;
            continue;
        } else if (ch == '(') {
            if (paren_depth > 0) {
                paren_depth -= 1;
                continue;
            } else {
                return idx + 1;
            }
        }

        if (ch == ']') {
            bracket_depth += 1;
            continue;
        } else if (ch == '[') {
            if (bracket_depth > 0) {
                bracket_depth -= 1;
                continue;
            } else {
                return idx + 1;
            }
        }

        if (ch == '}') {
            brace_depth += 1;
            continue;
        } else if (ch == '{') {
            if (brace_depth > 0) {
                brace_depth -= 1;
                continue;
            } else {
                return idx + 1;
            }
        }

        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            if (ch == ';' or ch == ',') return idx + 1;

            if (ch == '=') {
                const prev = if (idx > 0) src[idx - 1] else 0;
                const next = if (idx + 1 < src.len) src[idx + 1] else 0;
                if (prev != '=' and prev != '!' and prev != '<' and prev != '>' and next != '=' and next != '>') {
                    return idx + 1;
                }
            }

            if (idx >= 6 and std.mem.eql(u8, src[idx - 6 .. idx], "return") and
                (idx == 6 or !isIdentChar(src[idx - 7])))
            {
                return idx;
            }

            if (idx >= 5 and std.mem.eql(u8, src[idx - 5 .. idx], "yield") and
                (idx == 5 or !isIdentChar(src[idx - 6])))
            {
                return idx;
            }

            if (ch == '\n') {
                return idx + 1;
            }
        }
    }

    return 0;
}

fn findConditionEnd(src: []const u8, start: usize, q_idx: usize) usize {
    _ = start;
    var idx = q_idx;
    while (idx > 0 and (src[idx - 1] == ' ' or src[idx - 1] == '\t' or src[idx - 1] == '\r')) : (idx -= 1) {}
    return idx;
}

fn invertCondition(allocator: std.mem.Allocator, cond: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, cond, " \t\r\n");

    if (trimmed.len >= 2 and trimmed[0] == '!' and trimmed[1] != '=') {
        const inner = trimmed[1..];
        return allocator.dupe(u8, inner);
    }

    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
        return std.fmt.allocPrint(allocator, "!{s}", .{trimmed});
    }

    var is_compound = false;
    for (trimmed) |c| {
        if (c == ' ' or c == '=' or c == '<' or c == '>' or c == '&' or c == '|') {
            is_compound = true;
            break;
        }
    }

    if (is_compound) {
        return std.fmt.allocPrint(allocator, "!({s})", .{trimmed});
    }

    return std.fmt.allocPrint(allocator, "!{s}", .{trimmed});
}

pub fn rewriteDoubleNegation(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var changes: usize = 0;

    while (i < source.len) {
        if (source[i] == '"' or source[i] == '\'') {
            const quote = source[i];
            try out.append(allocator, quote);
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    try out.append(allocator, source[i]);
                    try out.append(allocator, source[i + 1]);
                    i += 2;
                } else {
                    try out.append(allocator, source[i]);
                    i += 1;
                }
            }
            if (i < source.len) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.append(allocator, '/');
            try out.append(allocator, '*');
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            if (i + 1 < source.len) {
                try out.append(allocator, '*');
                try out.append(allocator, '/');
                i += 2;
            }
            continue;
        }

        if (source[i] == '!' and i + 1 < source.len and source[i + 1] == '(') {
            const after_open = skipWhitespace(source, i + 2);
            if (after_open < source.len and source[after_open] == '!') {
                const next_char = if (after_open + 1 < source.len) source[after_open + 1] else 0;
                if (next_char != '=') {
                    const operand_start = after_open + 1;
                    const close_idx = findMatchingParen(source, i + 1);
                    if (close_idx != null and close_idx.? > operand_start) {
                        const raw_inner = source[operand_start..close_idx.?];
                        const inner = std.mem.trim(u8, raw_inner, " \t\r\n");
                        try out.appendSlice(allocator, inner);
                        i = close_idx.? + 1;
                        changes += 1;
                        continue;
                    }
                }
            }
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

fn findMatchingParen(src: []const u8, open_idx: usize) ?usize {
    var depth: i32 = 0;
    var i = open_idx;
    while (i < src.len) : (i += 1) {
        if (src[i] == '(') {
            depth += 1;
        } else if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

pub fn rewriteDeMorgan(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var changes: usize = 0;

    while (i < source.len) {
        if (source[i] == '"' or source[i] == '\'') {
            const quote = source[i];
            try out.append(allocator, quote);
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    try out.append(allocator, source[i]);
                    try out.append(allocator, source[i + 1]);
                    i += 2;
                } else {
                    try out.append(allocator, source[i]);
                    i += 1;
                }
            }
            if (i < source.len) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.append(allocator, '/');
            try out.append(allocator, '*');
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) {
                try out.append(allocator, source[i]);
                i += 1;
            }
            if (i + 1 < source.len) {
                try out.append(allocator, '*');
                try out.append(allocator, '/');
                i += 2;
            }
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

fn parseDeMorganInner(allocator: std.mem.Allocator, inner: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len < 5) return null;

    var op_is_or: ?bool = null;
    var terms: std.ArrayList([]const u8) = .empty;
    defer terms.deinit(allocator);

    var idx: usize = 0;
    while (idx < trimmed.len) {
        idx = skipWhitespace(trimmed, idx);
        if (idx >= trimmed.len) break;

        if (trimmed[idx] != '!') return null;
        if (idx + 1 < trimmed.len and trimmed[idx + 1] == '=') return null;

        idx += 1;
        idx = skipWhitespace(trimmed, idx);
        const term_start = idx;

        var paren_depth: i32 = 0;
        while (idx < trimmed.len) {
            const ch = trimmed[idx];
            if (ch == '(') {
                paren_depth += 1;
            } else if (ch == ')') {
                paren_depth -= 1;
            } else if (paren_depth == 0) {
                if (ch == '|' and idx + 1 < trimmed.len and trimmed[idx + 1] == '|') {
                    if (op_is_or == null) {
                        op_is_or = true;
                    } else if (op_is_or.? != true) {
                        return null;
                    }
                    break;
                } else if (ch == '&' and idx + 1 < trimmed.len and trimmed[idx + 1] == '&') {
                    if (op_is_or == null) {
                        op_is_or = false;
                    } else if (op_is_or.? != false) {
                        return null;
                    }
                    break;
                }
            }
            idx += 1;
        }

        const raw_term = trimmed[term_start..idx];
        const term = std.mem.trim(u8, raw_term, " \t\r\n");
        if (term.len == 0) return null;
        try terms.append(allocator, term);

        if (idx < trimmed.len) {
            idx += 2;
        }
    }

    if (terms.items.len < 2 or op_is_or == null) return null;

    const new_op: []const u8 = if (op_is_or.?) " && " else " || ";

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (terms.items, 0..) |t, t_idx| {
        if (t_idx > 0) try result.appendSlice(allocator, new_op);
        try result.appendSlice(allocator, t);
    }

    return try result.toOwnedSlice(allocator);
}

fn shouldWrapDeMorgan(src: []const u8, start: usize, end: usize) bool {
    var before_idx = start;
    while (before_idx > 0) {
        before_idx -= 1;
        const ch = src[before_idx];
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
            if (isOperatorChar(ch)) return true;
            break;
        }
    }

    var after_idx = end;
    while (after_idx < src.len) : (after_idx += 1) {
        const ch = src[after_idx];
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
            if (isOperatorChar(ch)) return true;
            break;
        }
    }

    return false;
}

fn isOperatorChar(ch: u8) bool {
    return ch == '&' or ch == '|' or ch == '!' or ch == '^' or
        ch == '?' or ch == ':' or ch == '+' or ch == '-' or
        ch == '*' or ch == '/' or ch == '%' or ch == '<' or
        ch == '>' or ch == '~' or ch == '=';
}

test "redundant ternary simplification - true/false" {
    const allocator = std.testing.allocator;
    const input = "return x === \"admin\" ? true : false;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("return x === \"admin\";", res);
}

test "redundant ternary simplification - single identifier" {
    const allocator = std.testing.allocator;
    const input = "const valid = isReady ? true : false;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const valid = isReady;", res);
}

test "inverted ternary simplification" {
    const allocator = std.testing.allocator;
    const input1 = "return isValid ? false : true;";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("return !isValid;", res1);

    const input2 = "return !isReady ? false : true;";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return isReady;", res2);

    const input3 = "return x > 0 ? false : true;";
    const res3 = try simplify(allocator, input3);
    defer allocator.free(res3);
    try std.testing.expectEqualStrings("return !(x > 0);", res3);
}

test "double negation simplification" {
    const allocator = std.testing.allocator;
    const input1 = "const a = !!x;";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("const a = x;", res1);

    const input2 = "return !(!isValid);";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return isValid;", res2);
}

test "de morgan law simplification" {
    const allocator = std.testing.allocator;
    const input1 = "return !(!a || !b);";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("return a && b;", res1);

    const input2 = "return !(!a && !b);";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return a || b;", res2);

    const input3 = "return !(!foo.bar || !baz.qux);";
    const res3 = try simplify(allocator, input3);
    defer allocator.free(res3);
    try std.testing.expectEqualStrings("return foo.bar && baz.qux;", res3);
}

test "skips string literals and comments" {
    const allocator = std.testing.allocator;
    const input = "const msg = \"x ? true : false\"; // !(!a || !b)\nconst y = !!z;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const msg = \"x ? true : false\"; // !(!a || !b)\nconst y = z;", res);
}

test "multi-pass combined simplification" {
    const allocator = std.testing.allocator;
    const input = "const res = !(!a || !b) ? true : false;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const res = (a && b);", res);
}

test "de morgan with outer comparison operator wrapping" {
    const allocator = std.testing.allocator;
    const input = "const ok = x == !(!a || !b);";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const ok = x == (a && b);", res);
}
