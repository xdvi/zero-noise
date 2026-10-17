const std = @import("std");
const treesitter = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub fn validateCandidateSyntax(filepath: []const u8, content: []const u8) !bool {
    return validateCandidateSyntaxDelta(filepath, "", content);
}

pub fn validateCandidateSyntaxDelta(filepath: []const u8, original: []const u8, candidate: []const u8) !bool {
    const lang = grammars.Language.fromPath(filepath);
    if (lang != .unknown) {
        return validateWithTreeSitter(lang, original, candidate);
    }

    if (checkBalancedBrackets(candidate)) return true;
    if (original.len > 0 and !checkBalancedBrackets(original)) {
        return true;
    }
    return false;
}

pub fn countSyntaxErrors(node: treesitter.TSNode) usize {
    if (!node.hasError()) return 0;
    var count: usize = 0;
    if (node.isError() or std.mem.eql(u8, node.getType(), "ERROR")) {
        count += 1;
    }
    const children = node.childCount();
    var idx: u32 = 0;
    while (idx < children) : (idx += 1) {
        count += countSyntaxErrors(node.child(idx));
    }
    return count;
}

pub fn checkBalancedBrackets(content: []const u8) bool {
    var stack: [1024]u8 = undefined;
    var top: usize = 0;

    var i: usize = 0;
    while (i < content.len) {
        if (skipSyntaxTrivia(content, i)) |next_i| {
            i = next_i;
            continue;
        }

        const ch = content[i];
        if (!handleBracket(ch, &stack, &top)) return false;

        i += 1;
    }

    return top == 0;
}

fn validateWithTreeSitter(lang: grammars.Language, original: []const u8, candidate: []const u8) bool {
    const ts_lang = lang.getTsLanguage() orelse return false;
    var parser = treesitter.Parser.init() catch return false;
    defer parser.deinit();
    if (!parser.setLanguage(ts_lang)) return false;

    var cand_tree = parser.parseString(candidate) catch return false;
    defer cand_tree.deinit();

    if (!cand_tree.rootNode().hasError()) return true;
    if (original.len == 0) return false;

    var orig_tree = parser.parseString(original) catch return false;
    defer orig_tree.deinit();

    if (!orig_tree.rootNode().hasError()) return false;

    const orig_err_count = countSyntaxErrors(orig_tree.rootNode());
    const cand_err_count = countSyntaxErrors(cand_tree.rootNode());
    return cand_err_count <= orig_err_count;
}

fn handleBracket(ch: u8, stack: *[1024]u8, top: *usize) bool {
    if (ch == '(' or ch == '[' or ch == '{') {
        if (top.* >= stack.len) return false;
        stack[top.*] = ch;
        top.* += 1;
        return true;
    }
    if (ch == ')' or ch == ']' or ch == '}') {
        if (top.* == 0) return false;
        const expected: u8 = switch (ch) {
            ')' => '(',
            ']' => '[',
            '}' => '{',
            else => 0,
        };
        top.* -= 1;
        return stack[top.*] == expected;
    }
    return true;
}

fn skipSyntaxTrivia(content: []const u8, idx: usize) ?usize {
    const ch = content[idx];
    if (ch == '"' or ch == '\'') return skipQuotedTrivia(content, idx, ch);
    if (ch == '`') return skipBacktickTrivia(content, idx);
    if (ch == '/' and idx + 1 < content.len and content[idx + 1] == '/') return skipLineCommentTrivia(content, idx);
    if (ch == '/' and idx + 1 < content.len and content[idx + 1] == '*') return skipBlockCommentTrivia(content, idx);
    return null;
}

fn skipQuotedTrivia(content: []const u8, idx: usize, quote: u8) ?usize {
    var i = idx + 1;
    while (i < content.len and content[i] != quote) {
        if (content[i] == '\\') i += 1;
        i += 1;
    }
    if (i < content.len) return i + 1;
    return content.len;
}

fn skipBacktickTrivia(content: []const u8, idx: usize) ?usize {
    var i = idx + 1;
    while (i < content.len and content[i] != '`') {
        if (content[i] == '\\' and i + 1 < content.len) i += 2 else i += 1;
    }
    if (i < content.len) return i + 1;
    return content.len;
}

fn skipLineCommentTrivia(content: []const u8, idx: usize) ?usize {
    var i = idx;
    while (i < content.len and content[i] != '\n') : (i += 1) {}
    return i;
}

fn skipBlockCommentTrivia(content: []const u8, idx: usize) ?usize {
    var i = idx + 2;
    while (i + 1 < content.len and !(content[i] == '*' and content[i + 1] == '/')) : (i += 1) {}
    if (i + 1 < content.len) return i + 2;
    return content.len;
}
