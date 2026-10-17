const std = @import("std");
const bindings = @import("bindings.zig");

pub const Language = enum {
    go,
    rust,
    python,
    typescript,
    tsx,
    c_sharp,
    unknown,

    pub fn getTsLanguage(self: Language) ?*const bindings.TSLanguage {
        const table = ts_language_table;
        const idx = @intFromEnum(self);
        if (idx >= table.len) return null;
        const loader = table[idx] orelse return null;
        return loader();
    }

    pub fn fromExtension(ext: []const u8) Language {
        for (extension_table) |entry| {
            if (std.mem.eql(u8, ext, entry.ext)) return entry.lang;
        }
        return .unknown;
    }

    pub fn fromPath(path: []const u8) Language {
        const ext = std.fs.path.extension(path);
        return fromExtension(ext);
    }

    pub fn fromName(name: []const u8) Language {
        for (name_table) |entry| {
            if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.lang;
        }
        return .unknown;
    }

    pub fn isFunction(self: Language, node_type: []const u8) bool {
        return isFunctionType(node_type, self);
    }

    pub fn isFunctionNode(self: Language, node: bindings.TSNode) bool {
        return checkFunctionNode(node, self);
    }

    pub fn isControl(self: Language, node_type: []const u8) bool {
        return isControlType(node_type, self);
    }

    pub fn isClosure(self: Language, node_type: []const u8) bool {
        return isClosureType(node_type, self);
    }

    pub fn isTernary(self: Language, node_type: []const u8) bool {
        return isTernaryType(node_type, self);
    }
};

const TsLanguageLoader = *const fn () callconv(.c) ?*const bindings.TSLanguage;

const ts_language_table: [@typeInfo(Language).@"enum".field_names.len]?TsLanguageLoader = .{
    bindings.tree_sitter_go,
    bindings.tree_sitter_rust,
    bindings.tree_sitter_python,
    bindings.tree_sitter_typescript,
    bindings.tree_sitter_tsx,
    bindings.tree_sitter_c_sharp,
    null,
};

const ExtensionEntry = struct {
    ext: []const u8,
    lang: Language,
};

const extension_table = [_]ExtensionEntry{
    .{ .ext = ".go", .lang = .go },
    .{ .ext = ".rs", .lang = .rust },
    .{ .ext = ".py", .lang = .python },
    .{ .ext = ".ts", .lang = .typescript },
    .{ .ext = ".tsx", .lang = .tsx },
    .{ .ext = ".jsx", .lang = .tsx },
    .{ .ext = ".js", .lang = .typescript },
    .{ .ext = ".cs", .lang = .c_sharp },
};

const NameEntry = struct {
    name: []const u8,
    lang: Language,
};

const name_table = [_]NameEntry{
    .{ .name = "go", .lang = .go },
    .{ .name = "rust", .lang = .rust },
    .{ .name = "rs", .lang = .rust },
    .{ .name = "python", .lang = .python },
    .{ .name = "py", .lang = .python },
    .{ .name = "typescript", .lang = .typescript },
    .{ .name = "ts", .lang = .typescript },
    .{ .name = "tsx", .lang = .tsx },
    .{ .name = "javascript", .lang = .typescript },
    .{ .name = "js", .lang = .typescript },
    .{ .name = "csharp", .lang = .c_sharp },
    .{ .name = "cs", .lang = .c_sharp },
    .{ .name = "c_sharp", .lang = .c_sharp },
};

pub fn isFunctionNode(node: bindings.TSNode, lang: Language) bool {
    return checkFunctionNode(node, lang);
}

fn checkFunctionNode(node: bindings.TSNode, lang: Language) bool {
    if (node.isNull()) return false;
    const t = node.getType();
    return switch (lang) {
        .go => std.mem.eql(u8, t, "function_declaration") or std.mem.eql(u8, t, "method_declaration"),
        .rust => std.mem.eql(u8, t, "function_item"),
        .python => std.mem.eql(u8, t, "function_definition"),
        .typescript, .tsx => blk: {
            if (std.mem.eql(u8, t, "function_declaration") or std.mem.eql(u8, t, "method_definition")) {
                break :blk true;
            }
            if (std.mem.eql(u8, t, "variable_declarator")) {
                const val = node.childByFieldName("value");
                if (!val.isNull()) {
                    const vt = val.getType();
                    if (std.mem.eql(u8, vt, "arrow_function") or std.mem.eql(u8, vt, "function_expression")) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        },
        .c_sharp => std.mem.eql(u8, t, "method_declaration") or
            std.mem.eql(u8, t, "local_function_statement") or
            std.mem.eql(u8, t, "constructor_declaration"),
        .unknown => false,
    };
}

pub fn isFunctionType(node_type: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "function_declaration") or std.mem.eql(u8, node_type, "method_declaration"),
        .rust => std.mem.eql(u8, node_type, "function_item"),
        .python => std.mem.eql(u8, node_type, "function_definition"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "function_declaration") or std.mem.eql(u8, node_type, "method_definition"),
        .c_sharp => std.mem.eql(u8, node_type, "method_declaration") or
            std.mem.eql(u8, node_type, "local_function_statement") or
            std.mem.eql(u8, node_type, "constructor_declaration"),
        .unknown => false,
    };
}

pub fn isControlType(node_type: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "if_statement") or
            std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "expression_switch_statement") or
            std.mem.eql(u8, node_type, "type_switch_statement") or
            std.mem.eql(u8, node_type, "select_statement"),
        .rust => std.mem.eql(u8, node_type, "if_expression") or
            std.mem.eql(u8, node_type, "for_expression") or
            std.mem.eql(u8, node_type, "while_expression") or
            std.mem.eql(u8, node_type, "loop_expression") or
            std.mem.eql(u8, node_type, "match_expression"),
        .python => std.mem.eql(u8, node_type, "if_statement") or
            std.mem.eql(u8, node_type, "elif_clause") or
            std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "while_statement") or
            std.mem.eql(u8, node_type, "match_statement") or
            std.mem.eql(u8, node_type, "except_clause"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "if_statement") or
            std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "for_in_statement") or
            std.mem.eql(u8, node_type, "for_of_statement") or
            std.mem.eql(u8, node_type, "while_statement") or
            std.mem.eql(u8, node_type, "do_statement") or
            std.mem.eql(u8, node_type, "switch_statement") or
            std.mem.eql(u8, node_type, "catch_clause"),
        .c_sharp => std.mem.eql(u8, node_type, "if_statement") or
            std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "for_each_statement") or
            std.mem.eql(u8, node_type, "while_statement") or
            std.mem.eql(u8, node_type, "do_statement") or
            std.mem.eql(u8, node_type, "switch_statement") or
            std.mem.eql(u8, node_type, "catch_clause"),
        .unknown => false,
    };
}

pub fn isClosureType(node_type: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "func_literal"),
        .rust => std.mem.eql(u8, node_type, "closure_expression"),
        .python => std.mem.eql(u8, node_type, "lambda"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "arrow_function") or
            std.mem.eql(u8, node_type, "function_expression"),
        .c_sharp => std.mem.eql(u8, node_type, "lambda_expression") or
            std.mem.eql(u8, node_type, "anonymous_method_expression"),
        .unknown => false,
    };
}

pub fn isTernaryType(node_type: []const u8, lang: Language) bool {
    return switch (lang) {
        .typescript, .tsx => std.mem.eql(u8, node_type, "ternary_expression"),
        .c_sharp, .python => std.mem.eql(u8, node_type, "conditional_expression"),
        .rust => std.mem.eql(u8, node_type, "if_expression"),
        else => false,
    };
}

pub fn isElseIfNode(node: bindings.TSNode, lang: Language) bool {
    const t = node.getType();
    if (lang == .python and std.mem.eql(u8, t, "elif_clause")) return true;

    const is_if = std.mem.eql(u8, t, "if_statement") or std.mem.eql(u8, t, "if_expression");
    if (!is_if) return false;

    const p = node.parent();
    if (p.isNull()) return false;
    const pt = p.getType();

    if (lang == .go and std.mem.eql(u8, pt, "if_statement")) {
        const alt = p.childByFieldName("alternative");
        if (!alt.isNull() and alt.startByte() == node.startByte()) return true;
    } else if (lang == .rust and (std.mem.eql(u8, pt, "else_clause") or std.mem.eql(u8, pt, "if_expression"))) {
        return true;
    } else if (std.mem.eql(u8, pt, "else_clause")) {
        return true;
    }
    return false;
}

pub fn isIdentifierType(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "identifier") or
        std.mem.eql(u8, node_type, "type_identifier") or
        std.mem.eql(u8, node_type, "field_identifier") or
        std.mem.eql(u8, node_type, "property_identifier") or
        std.mem.eql(u8, node_type, "shorthand_property_identifier");
}

pub fn getLineSnippet(source: []const u8, row: u32) []const u8 {
    var cur_row: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (cur_row == row) {
                return std.mem.trim(u8, source[line_start..i], " \t\r");
            }
            cur_row += 1;
            line_start = i + 1;
        }
    }
    if (cur_row == row) {
        return std.mem.trim(u8, source[line_start..], " \t\r");
    }
    return "";
}

pub fn getLogicalOperator(node: bindings.TSNode, source: []const u8, lang: Language) ?[]const u8 {
    const t = node.getType();
    if (lang == .python) {
        if (std.mem.eql(u8, t, "boolean_operator")) {
            var i: u32 = 0;
            const count = node.childCount();
            while (i < count) : (i += 1) {
                const ch = node.child(i);
                const slice = ch.slice(source);
                if (std.mem.eql(u8, slice, "and") or std.mem.eql(u8, slice, "or")) {
                    return slice;
                }
            }
        }
        return null;
    }

    if (std.mem.eql(u8, t, "binary_expression")) {
        var i: u32 = 0;
        const count = node.childCount();
        while (i < count) : (i += 1) {
            const ch = node.child(i);
            const slice = ch.slice(source);
            if (std.mem.eql(u8, slice, "&&") or std.mem.eql(u8, slice, "||")) {
                return slice;
            }
        }
    }
    return null;
}

test "getLineSnippet extracts correct trimmed row" {
    try std.testing.expectEqualStrings("test", getLineSnippet("hello\n  test  \nworld", 1));
}

test "isFunctionNode recognizes variable_declarator with arrow_function and function_expression in TypeScript" {
    const ts_lang = Language.typescript.getTsLanguage() orelse return error.LanguageNotAvailable;
    var parser = try bindings.Parser.init();
    defer parser.deinit();
    _ = parser.setLanguage(ts_lang);

    const source =
        \\const arrowFn = (x: number) => x * 2;
        \\const exprFn = function(y: number) { return y * 2; };
        \\const regularVar = 42;
        \\function regularFn() {}
    ;
    var tree = try parser.parseString(source);
    defer tree.deinit();

    const root = tree.rootNode();
    var found_arrow = false;
    var found_expr = false;
    var found_regular_var_as_fn = false;
    var found_decl = false;

    var i: u32 = 0;
    while (i < root.childCount()) : (i += 1) {
        const stmt = root.child(i);
        if (std.mem.eql(u8, stmt.getType(), "lexical_declaration")) {
            var j: u32 = 0;
            while (j < stmt.childCount()) : (j += 1) {
                const ch = stmt.child(j);
                if (std.mem.eql(u8, ch.getType(), "variable_declarator")) {
                    const name_node = ch.childByFieldName("name");
                    const name = name_node.slice(source);
                    const is_fn = isFunctionNode(ch, .typescript);
                    if (std.mem.eql(u8, name, "arrowFn")) {
                        found_arrow = is_fn;
                    } else if (std.mem.eql(u8, name, "exprFn")) {
                        found_expr = is_fn;
                    } else if (std.mem.eql(u8, name, "regularVar")) {
                        found_regular_var_as_fn = is_fn;
                    }
                }
            }
        } else if (std.mem.eql(u8, stmt.getType(), "function_declaration")) {
            found_decl = isFunctionNode(stmt, .typescript);
        }
    }

    try std.testing.expect(found_arrow);
    try std.testing.expect(found_expr);
    try std.testing.expect(!found_regular_var_as_fn);
    try std.testing.expect(found_decl);
}



