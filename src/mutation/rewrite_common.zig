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

    if (src[idx] == '/' and idx + 1 < src.len and src[idx + 1] == '/') {
        var i = idx + 2;
        while (i < src.len and src[i] != '\n') : (i += 1) {}
        return i;
    }

    if (src[idx] == '/' and idx + 1 < src.len and src[idx + 1] == '*') {
        var i = idx + 2;
        while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
        if (i + 1 < src.len) return i + 2;
        return src.len;
    }

    if (src[idx] == '#') {
        var i = idx + 1;
        while (i < src.len and src[i] != '\n') : (i += 1) {}
        return i;
    }

    if (src[idx] == 'r' and idx + 1 < src.len) {
        var h: usize = 0;
        var p = idx + 1;
        while (p < src.len and src[p] == '#') : (p += 1) {
            h += 1;
        }
        if (p < src.len and (src[p] == '"' or (h == 0 and src[p] == '\''))) {
            const quote = src[p];
            var i = p + 1;
            while (i < src.len) {
                if (src[i] == quote) {
                    var matched = true;
                    if (i + 1 + h > src.len) {
                        matched = false;
                    } else {
                        for (0..h) |k| {
                            if (src[i + 1 + k] != '#') {
                                matched = false;
                                break;
                            }
                        }
                    }
                    if (matched) {
                        return i + 1 + h;
                    }
                }
                i += 1;
            }
            return src.len;
        }
    }

    if (src[idx] == '@' and idx + 1 < src.len and src[idx + 1] == '"') {
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

    if (src[idx] == '`') {
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

    if (src[idx] == '"' or src[idx] == '\'') {
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

    return null;
}

pub fn isCSharp(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "using System") != null) return true;
    if (std.mem.indexOf(u8, source, "namespace ") != null) return true;
    if (std.mem.indexOf(u8, source, "public class ") != null) return true;
    if (std.mem.indexOf(u8, source, "internal class ") != null) return true;
    if (std.mem.indexOf(u8, source, "private class ") != null) return true;
    if (std.mem.indexOf(u8, source, "Console.WriteLine") != null) return true;
    if (std.mem.indexOf(u8, source, "bool ") != null) return true;
    return false;
}

pub fn isAlreadyBoolean(cond: []const u8) bool {
    const trimmed = std.mem.trim(u8, cond, " \t\r\n");
    if (trimmed.len == 0) return false;

    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false") or
        std.mem.eql(u8, trimmed, "True") or std.mem.eql(u8, trimmed, "False"))
    {
        return true;
    }

    if (trimmed[0] == '!' and (trimmed.len == 1 or trimmed[1] != '=')) {
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "Boolean(") or std.mem.startsWith(u8, trimmed, "bool(")) {
        return true;
    }

    var paren_depth: i32 = 0;
    var idx: usize = 0;
    while (idx < trimmed.len) {
        if (skipTriviaOrLiteral(trimmed, idx)) |next_idx| {
            idx = next_idx;
            continue;
        }

        const ch = trimmed[idx];
        if (ch == '(') {
            paren_depth += 1;
        } else if (ch == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (paren_depth == 0) {
            if (ch == '=' and idx + 1 < trimmed.len and (trimmed[idx + 1] == '=' or trimmed[idx + 1] == '>')) {
                return true;
            }
            if (ch == '!' and idx + 1 < trimmed.len and trimmed[idx + 1] == '=') {
                return true;
            }
            if (ch == '<' or ch == '>') {
                return true;
            }
            if (ch == '&' and idx + 1 < trimmed.len and trimmed[idx + 1] == '&') {
                return true;
            }
            if (ch == '|' and idx + 1 < trimmed.len and trimmed[idx + 1] == '|') {
                return true;
            }
        }
        idx += 1;
    }

    if (std.mem.indexOf(u8, trimmed, ".includes(") != null or
        std.mem.indexOf(u8, trimmed, ".startsWith(") != null or
        std.mem.indexOf(u8, trimmed, ".endsWith(") != null or
        std.mem.indexOf(u8, trimmed, ".has(") != null or
        std.mem.indexOf(u8, trimmed, ".is(") != null)
    {
        return true;
    }

    const last_ident = if (std.mem.lastIndexOf(u8, trimmed, ".")) |dot_pos|
        trimmed[dot_pos + 1 ..]
    else
        trimmed;

    const bool_prefixes = [_][]const u8{
        "is",       "Is",
        "has",      "Has",
        "can",      "Can",
        "should",   "Should",
        "was",      "Was",
        "contains", "Contains",
        "valid",    "Valid",
        "ok",       "Ok",
        "ready",    "Ready",
        "enabled",  "Enabled",
        "disabled", "Disabled",
        "cond",     "Cond",
    };

    for (bool_prefixes) |prefix| {
        if (std.mem.startsWith(u8, last_ident, prefix)) {
            if (last_ident.len == prefix.len) return true;
            const next_ch = last_ident[prefix.len];
            if (std.ascii.isUpper(next_ch) or next_ch == '_' or !std.ascii.isAlphabetic(next_ch)) {
                return true;
            }
            if (std.mem.eql(u8, prefix, "valid") or std.mem.eql(u8, prefix, "ready") or
                std.mem.eql(u8, prefix, "cond") or std.mem.eql(u8, prefix, "enabled") or
                std.mem.eql(u8, prefix, "disabled"))
            {
                return true;
            }
        }
    }

    return false;
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

