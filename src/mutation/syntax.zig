const std = @import("std");
const treesitter = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub fn validateCandidateSyntax(filepath: []const u8, content: []const u8) !bool {
    return validateCandidateSyntaxDelta(filepath, "", content);
}

pub fn validateCandidateSyntaxDelta(filepath: []const u8, original: []const u8, candidate: []const u8) !bool {
    const lang = grammars.Language.fromPath(filepath);
    if (lang != .unknown) {
        const ts_lang = lang.getTsLanguage() orelse return false; // fail closed
        var parser = treesitter.Parser.init() catch return false; // fail closed
        defer parser.deinit();
        if (!parser.setLanguage(ts_lang)) return false; // fail closed

        var cand_tree = parser.parseString(candidate) catch return false;
        defer cand_tree.deinit();

        const cand_has_err = cand_tree.rootNode().hasError();
        if (!cand_has_err) return true;

        if (original.len == 0) return false;

        var orig_tree = parser.parseString(original) catch return false;
        defer orig_tree.deinit();

        const orig_has_err = orig_tree.rootNode().hasError();
        if (!orig_has_err) {
            return false;
        }

        const orig_err_count = countSyntaxErrors(orig_tree.rootNode());
        const cand_err_count = countSyntaxErrors(cand_tree.rootNode());
        if (cand_err_count > orig_err_count) {
            return false;
        }
        return true;
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
        const ch = content[i];

        if (ch == '"' or ch == '\'') {
            i += 1;
            while (i < content.len and content[i] != ch) {
                if (content[i] == '\\') i += 1;
                i += 1;
            }
            if (i < content.len) i += 1;
            continue;
        }

        if (ch == '`') {
            i += 1;
            while (i < content.len and content[i] != '`') {
                if (content[i] == '\\' and i + 1 < content.len) i += 2 else i += 1;
            }
            if (i < content.len) i += 1;
            continue;
        }

        if (ch == '/' and i + 1 < content.len and content[i + 1] == '/') {
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            continue;
        }

        if (ch == '/' and i + 1 < content.len and content[i + 1] == '*') {
            i += 2;
            while (i + 1 < content.len and !(content[i] == '*' and content[i + 1] == '/')) : (i += 1) {}
            if (i + 1 < content.len) i += 2;
            continue;
        }

        if (ch == '(' or ch == '[' or ch == '{') {
            if (top >= stack.len) return false;
            stack[top] = ch;
            top += 1;
        } else if (ch == ')' or ch == ']' or ch == '}') {
            if (top == 0) return false;
            const expected: u8 = switch (ch) {
                ')' => '(',
                ']' => '[',
                '}' => '{',
                else => 0,
            };
            top -= 1;
            if (stack[top] != expected) return false;
        }

        i += 1;
    }

    return top == 0;
}
