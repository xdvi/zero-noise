const std = @import("std");

pub const RewriteResult = struct {
    output: []u8,
    changes_count: usize,

    pub fn deinit(self: *RewriteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

pub fn skipWhitespace(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) : (i += 1) {}
    return i;
}

pub fn matchKeyword(src: []const u8, idx: usize, kw: []const u8) bool {
    if (idx + kw.len > src.len) return false;
    if (!std.mem.eql(u8, src[idx .. idx + kw.len], kw)) return false;
    if (idx + kw.len < src.len and isIdentChar(src[idx + kw.len])) return false;
    return true;
}

pub fn skipTriviaOrLiteral(src: []const u8, idx: usize) ?usize {
    if (idx >= src.len) return null;

    if (skipLineComment(src, idx)) |r| return r;
    if (skipBlockComment(src, idx)) |r| return r;
    if (skipHashComment(src, idx)) |r| return r;
    if (skipRawString(src, idx)) |r| return r;
    if (skipVerbatimString(src, idx)) |r| return r;
    if (skipBacktickString(src, idx)) |r| return r;
    if (skipQuotedString(src, idx)) |r| return r;

    return null;
}

fn skipLineComment(src: []const u8, idx: usize) ?usize {
    if (src[idx] != '/' or idx + 1 >= src.len or src[idx + 1] != '/') return null;
    var i = idx + 2;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    return i;
}

fn skipBlockComment(src: []const u8, idx: usize) ?usize {
    if (src[idx] != '/' or idx + 1 >= src.len or src[idx + 1] != '*') return null;
    var i = idx + 2;
    while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
    if (i + 1 < src.len) return i + 2;
    return src.len;
}

fn skipHashComment(src: []const u8, idx: usize) ?usize {
    if (src[idx] != '#') return null;
    var i = idx + 1;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    return i;
}

fn skipRawString(src: []const u8, idx: usize) ?usize {
    if (src[idx] != 'r' or idx + 1 >= src.len) return null;
    var h: usize = 0;
    var p = idx + 1;
    while (p < src.len and src[p] == '#') : (p += 1) {
        h += 1;
    }
    if (p >= src.len) return null;
    if (!(src[p] == '"' or (h == 0 and src[p] == '\''))) return null;
    const quote = src[p];

    var i = p + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] != quote) continue;
        if (rawStringClosingMatches(src, i, h)) return i + 1 + h;
    }
    return src.len;
}

fn rawStringClosingMatches(src: []const u8, idx: usize, hashes: usize) bool {
    if (idx + 1 + hashes > src.len) return false;
    var k: usize = 0;
    while (k < hashes) : (k += 1) {
        if (src[idx + 1 + k] != '#') return false;
    }
    return true;
}

fn skipVerbatimString(src: []const u8, idx: usize) ?usize {
    if (src[idx] != '@' or idx + 1 >= src.len or src[idx + 1] != '"') return null;
    var i = idx + 2;
    while (i < src.len) {
        if (src[i] == '"') {
            if (i + 1 < src.len and src[i + 1] == '"') {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return src.len;
}

fn skipBacktickString(src: []const u8, idx: usize) ?usize {
    if (src[idx] != '`') return null;
    var i = idx + 1;
    while (i < src.len and src[i] != '`') {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 2;
        } else {
            i += 1;
        }
    }
    if (i < src.len) return i + 1;
    return src.len;
}

fn skipQuotedString(src: []const u8, idx: usize) ?usize {
    if (src[idx] != '"' and src[idx] != '\'') return null;
    const quote = src[idx];
    var i = idx + 1;
    while (i < src.len and src[i] != quote) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 2;
        } else {
            i += 1;
        }
    }
    if (i < src.len) return i + 1;
    return src.len;
}


pub fn findConditionStart(src: []const u8, q_idx: usize) usize {
    var idx = q_idx;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;

    while (idx > 0) {
        idx -= 1;
        const ch = src[idx];

        if (ch == '"' or ch == '\'' or ch == '`') {
            const quote = ch;
            while (idx > 0) {
                idx -= 1;
                if (src[idx] == quote) {
                    var slash_count: usize = 0;
                    var s = idx;
                    while (s > 0 and src[s - 1] == '\\') {
                        slash_count += 1;
                        s -= 1;
                    }
                    if (slash_count % 2 == 0) {
                        break;
                    }
                }
            }
            continue;
        }

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

            if (ch == '>' and idx > 0 and src[idx - 1] == '=') {
                return idx + 1;
            }
            if (ch == '=' and idx + 1 < src.len and src[idx + 1] == '>') {
                return idx + 2;
            }

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

pub fn findConditionEnd(src: []const u8, start: usize, q_idx: usize) usize {
    _ = start;
    var idx = q_idx;
    while (idx > 0 and (src[idx - 1] == ' ' or src[idx - 1] == '\t' or src[idx - 1] == '\r')) : (idx -= 1) {}
    return idx;
}

pub fn invertCondition(allocator: std.mem.Allocator, cond: []const u8) ![]u8 {
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

pub fn findMatchingParen(src: []const u8, open_idx: usize) ?usize {
    var depth: i32 = 0;
    var i = open_idx;
    while (i < src.len) {
        if (skipTriviaOrLiteral(src, i)) |next_i| {
            i = next_i;
            continue;
        }
        if (src[i] == '(') {
            depth += 1;
        } else if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

pub fn parseDeMorganInner(allocator: std.mem.Allocator, inner: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len < 5) return null;

    var terms: std.ArrayList([]const u8) = .empty;
    defer terms.deinit(allocator);
    var op_is_or: ?bool = null;

    if (!collectDeMorganTerms(allocator, trimmed, &terms, &op_is_or)) return null;

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

fn collectDeMorganTerms(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    terms: *std.ArrayList([]const u8),
    op_is_or: *?bool,
) bool {
    var idx: usize = 0;
    while (idx < trimmed.len) {
        idx = skipWhitespace(trimmed, idx);
        if (idx >= trimmed.len) break;

        if (trimmed[idx] != '!') return false;
        if (idx + 1 < trimmed.len and trimmed[idx + 1] == '=') return false;

        idx += 1;
        idx = skipWhitespace(trimmed, idx);
        const term_start = idx;

        const term_end = findTermEnd(trimmed, idx, op_is_or) orelse return false;
        idx = term_end;

        const raw_term = trimmed[term_start..idx];
        const term = std.mem.trim(u8, raw_term, " \t\r\n");
        if (term.len == 0) return false;
        terms.append(allocator, term) catch return false;

        if (idx < trimmed.len) {
            idx += 2;
        }
    }
    return true;
}

pub fn shouldWrapDeMorgan(src: []const u8, start: usize, end: usize) bool {
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

pub fn isOperatorChar(ch: u8) bool {
    return ch == '&' or ch == '|' or ch == '!' or ch == '^' or
        ch == '?' or ch == ':' or ch == '+' or ch == '-' or
        ch == '*' or ch == '/' or ch == '%' or ch == '<' or
        ch == '>' or ch == '~' or ch == '=';
}

fn updateDeMorganOperator(op_is_or: *?bool, is_or: bool) bool {
    if (op_is_or.* == null) {
        op_is_or.* = is_or;
        return true;
    }
    return op_is_or.*.? == is_or;
}

fn findTermEnd(trimmed: []const u8, start_idx: usize, op_is_or: *?bool) ?usize {
    var idx = start_idx;
    var paren_depth: i32 = 0;
    while (idx < trimmed.len) {
        if (skipTriviaOrLiteral(trimmed, idx)) |next_idx| {
            idx = next_idx;
            continue;
        }
        const ch = trimmed[idx];
        if (ch == '(') {
            paren_depth += 1;
        } else if (ch == ')') {
            paren_depth -= 1;
        } else if (paren_depth == 0) {
            if (ch == '|' and idx + 1 < trimmed.len and trimmed[idx + 1] == '|') {
                if (!updateDeMorganOperator(op_is_or, true)) return null;
                return idx;
            }
            if (ch == '&' and idx + 1 < trimmed.len and trimmed[idx + 1] == '&') {
                if (!updateDeMorganOperator(op_is_or, false)) return null;
                return idx;
            }
        }
        idx += 1;
    }
    return trimmed.len;
}
