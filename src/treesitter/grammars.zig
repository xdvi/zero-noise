const std = @import("std");
const bindings = @import("bindings.zig");

pub const Language = enum {
    go,
    rust,
    python,
    typescript,
    tsx,
    c_sharp,
    zig,
    unknown,

    pub fn getTsLanguage(self: Language) ?*const bindings.TSLanguage {
        return loadGrammarLanguage(self);
    }

    pub fn fromExtension(ext: []const u8) Language {
        for (std.enums.values(Language)) |lang| {
            for (specFor(lang).extensions) |entry_ext| {
                if (std.mem.eql(u8, ext, entry_ext)) return lang;
            }
        }
        return .unknown;
    }

    pub fn fromPath(path: []const u8) Language {
        const ext = std.fs.path.extension(path);
        return fromExtension(ext);
    }

    pub fn fromName(name: []const u8) Language {
        for (std.enums.values(Language)) |lang| {
            for (specFor(lang).names) |entry_name| {
                if (std.ascii.eqlIgnoreCase(name, entry_name)) return lang;
            }
        }
        return .unknown;
    }

    pub fn isFunction(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).function_nodes, node_type);
    }

    pub fn isFunctionNode(self: Language, node: bindings.TSNode) bool {
        if (node.isNull()) return false;
        const t = node.getType();
        if (contains(specFor(self).function_nodes, t)) return true;
        if (self == .typescript or self == .tsx) {
            if (std.mem.eql(u8, t, "variable_declarator")) {
                const val = node.childByFieldName("value");
                if (!val.isNull()) {
                    const vt = val.getType();
                    if (std.mem.eql(u8, vt, "arrow_function") or std.mem.eql(u8, vt, "function_expression")) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    pub fn isControl(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).control_nodes, node_type);
    }

    pub fn isClosure(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).closure_nodes, node_type);
    }

    pub fn isTernary(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).ternary_type_nodes, node_type);
    }

    pub fn isIfNode(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).if_nodes, node_type);
    }

    pub fn isElseNode(self: Language, node: bindings.TSNode) bool {
        const t = node.getType();
        if (self == .python) {
            return std.mem.eql(u8, t, "else_clause");
        }

        if (self == .go) {
            const p = node.parent();
            if (!p.isNull() and std.mem.eql(u8, p.getType(), "if_statement")) {
                const alt = p.childByFieldName("alternative");
                if (!alt.isNull() and alt.startByte() == node.startByte()) {
                    return std.mem.eql(u8, t, "block");
                }
            }
            return false;
        }

        if (std.mem.eql(u8, t, "else_clause")) {
            var i: u32 = 0;
            const count = node.childCount();
            while (i < count) : (i += 1) {
                const ch_type = node.child(i).getType();
                if (std.mem.eql(u8, ch_type, "if_statement") or std.mem.eql(u8, ch_type, "if_expression")) {
                    return false;
                }
            }
            return true;
        }

        return false;
    }

    pub fn isElseIfNode(self: Language, node: bindings.TSNode) bool {
        const t = node.getType();
        const sp = specFor(self);
        if (contains(sp.else_if_nodes, t)) return true;

        const is_if = std.mem.eql(u8, t, "if_statement") or std.mem.eql(u8, t, "if_expression");
        if (!is_if) return false;

        const p = node.parent();
        if (p.isNull()) return false;
        const pt = p.getType();

        if (self == .go and std.mem.eql(u8, pt, "if_statement")) {
            const alt = p.childByFieldName("alternative");
            if (!alt.isNull() and alt.startByte() == node.startByte()) return true;
        } else if (self == .rust and (std.mem.eql(u8, pt, "else_clause") or std.mem.eql(u8, pt, "if_expression"))) {
            return true;
        } else if (std.mem.eql(u8, pt, "else_clause")) {
            return true;
        }
        return false;
    }

    pub fn isTernaryNode(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).ternary_nodes, node_type);
    }

    pub fn isSwitchNode(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).switch_nodes, node_type);
    }

    pub fn isLoopNode(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).loop_nodes, node_type);
    }

    pub fn isCatchNode(self: Language, node_type: []const u8) bool {
        return contains(specFor(self).catch_nodes, node_type);
    }

    pub fn isIfOrWhile(self: Language, node_type: []const u8) bool {
        return isIfOrWhileType(node_type, self);
    }

    pub fn spec(self: Language) *const LanguageSpec {
        return specFor(self);
    }
};

const TsLanguageLoader = *const fn () callconv(.c) ?*const bindings.TSLanguage;

pub const LanguageSpec = struct {
    function_nodes: []const []const u8 = &.{},
    control_nodes: []const []const u8 = &.{},
    closure_nodes: []const []const u8 = &.{},
    ternary_nodes: []const []const u8 = &.{},
    ternary_type_nodes: []const []const u8 = &.{},
    if_nodes: []const []const u8 = &.{},
    else_if_nodes: []const []const u8 = &.{},
    else_nodes: []const []const u8 = &.{},
    loop_nodes: []const []const u8 = &.{},
    switch_nodes: []const []const u8 = &.{},
    catch_nodes: []const []const u8 = &.{},
    extensions: []const []const u8 = &.{},
    names: []const []const u8 = &.{},
    ts_language_loader: ?TsLanguageLoader = null,
};

fn specFor(lang: Language) *const LanguageSpec {
    return &language_specs[@backingInt(lang)];
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn isIfOrWhileType(node_type: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "if_statement") or std.mem.eql(u8, node_type, "for_statement"),
        .rust => std.mem.eql(u8, node_type, "if_expression") or std.mem.eql(u8, node_type, "while_expression"),
        .python => std.mem.eql(u8, node_type, "if_statement") or std.mem.eql(u8, node_type, "elif_clause") or std.mem.eql(u8, node_type, "while_statement"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "if_statement") or std.mem.eql(u8, node_type, "while_statement") or std.mem.eql(u8, node_type, "do_statement"),
        .c_sharp => std.mem.eql(u8, node_type, "if_statement") or std.mem.eql(u8, node_type, "while_statement") or std.mem.eql(u8, node_type, "do_statement"),
        .zig, .unknown => false,
    };
}

pub const language_specs: [@typeInfo(Language).@"enum".field_names.len]LanguageSpec = .{ // go
    .{
        .function_nodes = &.{ "function_declaration", "method_declaration" },
        .control_nodes = &.{ "if_statement", "for_statement", "expression_switch_statement", "type_switch_statement", "select_statement" },
        .closure_nodes = &.{"func_literal"},
        .ternary_nodes = &.{},
        .ternary_type_nodes = &.{},
        .if_nodes = &.{"if_statement"},
        .else_if_nodes = &.{},
        .loop_nodes = &.{"for_statement"},
        .switch_nodes = &.{ "expression_switch_statement", "type_switch_statement", "select_statement" },
        .catch_nodes = &.{},
        .extensions = &.{".go"},
        .names = &.{"go"},
        .ts_language_loader = null,
    },
    // rust
    .{
        .function_nodes = &.{"function_item"},
        .control_nodes = &.{ "if_expression", "for_expression", "while_expression", "loop_expression", "match_expression" },
        .closure_nodes = &.{"closure_expression"},
        .ternary_nodes = &.{},
        .ternary_type_nodes = &.{"if_expression"},
        .if_nodes = &.{"if_expression"},
        .else_if_nodes = &.{},
        .loop_nodes = &.{ "for_expression", "while_expression", "loop_expression" },
        .switch_nodes = &.{"match_expression"},
        .catch_nodes = &.{},
        .extensions = &.{".rs"},
        .names = &.{ "rust", "rs" },
        .ts_language_loader = null,
    },
    // python
    .{
        .function_nodes = &.{"function_definition"},
        .control_nodes = &.{ "if_statement", "elif_clause", "for_statement", "while_statement", "match_statement", "except_clause" },
        .closure_nodes = &.{"lambda"},
        .ternary_nodes = &.{"conditional_expression"},
        .ternary_type_nodes = &.{"conditional_expression"},
        .if_nodes = &.{ "if_statement", "elif_clause" },
        .else_if_nodes = &.{"elif_clause"},
        .loop_nodes = &.{ "for_statement", "while_statement" },
        .switch_nodes = &.{"match_statement"},
        .catch_nodes = &.{ "except_clause", "except_group_clause" },
        .extensions = &.{".py"},
        .names = &.{ "python", "py" },
        .ts_language_loader = null,
    },
    // typescript
    .{
        .function_nodes = &.{ "function_declaration", "method_definition" },
        .control_nodes = &.{ "if_statement", "for_statement", "for_in_statement", "for_of_statement", "while_statement", "do_statement", "switch_statement", "catch_clause" },
        .closure_nodes = &.{ "arrow_function", "function_expression" },
        .ternary_nodes = &.{"ternary_expression"},
        .ternary_type_nodes = &.{"ternary_expression"},
        .if_nodes = &.{"if_statement"},
        .else_if_nodes = &.{},
        .loop_nodes = &.{ "for_statement", "for_in_statement", "for_of_statement", "while_statement", "do_statement" },
        .switch_nodes = &.{"switch_statement"},
        .catch_nodes = &.{"catch_clause"},
        .extensions = &.{ ".ts", ".js" },
        .names = &.{ "typescript", "ts", "javascript", "js" },
        .ts_language_loader = null,
    },
    // tsx
    .{
        .function_nodes = &.{ "function_declaration", "method_definition" },
        .control_nodes = &.{ "if_statement", "for_statement", "for_in_statement", "for_of_statement", "while_statement", "do_statement", "switch_statement", "catch_clause" },
        .closure_nodes = &.{ "arrow_function", "function_expression" },
        .ternary_nodes = &.{"ternary_expression"},
        .ternary_type_nodes = &.{"ternary_expression"},
        .if_nodes = &.{"if_statement"},
        .else_if_nodes = &.{},
        .loop_nodes = &.{ "for_statement", "for_in_statement", "for_of_statement", "while_statement", "do_statement" },
        .switch_nodes = &.{"switch_statement"},
        .catch_nodes = &.{"catch_clause"},
        .extensions = &.{ ".tsx", ".jsx" },
        .names = &.{"tsx"},
        .ts_language_loader = null,
    },
    // c_sharp
    .{
        .function_nodes = &.{ "method_declaration", "local_function_statement", "constructor_declaration" },
        .control_nodes = &.{ "if_statement", "for_statement", "for_each_statement", "while_statement", "do_statement", "switch_statement", "catch_clause" },
        .closure_nodes = &.{ "lambda_expression", "anonymous_method_expression" },
        .ternary_nodes = &.{"conditional_expression"},
        .ternary_type_nodes = &.{"conditional_expression"},
        .if_nodes = &.{"if_statement"},
        .else_if_nodes = &.{},
        .loop_nodes = &.{ "for_statement", "for_each_statement", "while_statement", "do_statement" },
        .switch_nodes = &.{ "switch_statement", "switch_expression" },
        .catch_nodes = &.{"catch_clause"},
        .extensions = &.{".cs"},
        .names = &.{ "csharp", "cs", "c_sharp" },
        .ts_language_loader = null,
    },
    // zig
    .{
        .function_nodes = &.{"function_declaration"},
        .control_nodes = &.{ "if_statement", "if_expression", "for_statement", "for_expression", "while_statement", "while_expression", "switch_expression", "catch_expression" },
        .closure_nodes = &.{},
        .ternary_nodes = &.{},
        .ternary_type_nodes = &.{},
        .if_nodes = &.{ "if_statement", "if_expression" },
        .loop_nodes = &.{ "for_statement", "for_expression", "while_statement", "while_expression" },
        .switch_nodes = &.{"switch_expression"},
        .catch_nodes = &.{"catch_expression"},
        .extensions = &.{".zig"},
        .names = &.{ "zig", "ziglang" },
        .ts_language_loader = null,
    },
    // unknown
    .{},
};

pub const specs = language_specs;

pub fn isFunctionNode(node: bindings.TSNode, lang: Language) bool {
    return lang.isFunctionNode(node);
}

pub fn isElseIfNode(node: bindings.TSNode, lang: Language) bool {
    return lang.isElseIfNode(node);
}

pub fn isIfNode(node_type: []const u8, lang: Language) bool {
    return lang.isIfNode(node_type);
}

pub fn isElseNode(node: bindings.TSNode, lang: Language) bool {
    return lang.isElseNode(node);
}

pub fn isTernaryNode(node_type: []const u8, lang: Language) bool {
    return lang.isTernaryNode(node_type);
}

pub fn isSwitchNode(node_type: []const u8, lang: Language) bool {
    return lang.isSwitchNode(node_type);
}

pub fn isLoopNode(node_type: []const u8, lang: Language) bool {
    return lang.isLoopNode(node_type);
}

pub fn isCatchNode(node_type: []const u8, lang: Language) bool {
    return lang.isCatchNode(node_type);
}

pub fn isIfOrWhile(node_type: []const u8, lang: Language) bool {
    return lang.isIfOrWhile(node_type);
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
    if (lang == .python and std.mem.eql(u8, t, "boolean_operator")) {
        return findPythonLogicalOperator(node, source);
    }
    if (std.mem.eql(u8, t, "binary_expression")) {
        return findBinaryLogicalOperator(node, source);
    }
    return null;
}

fn findPythonLogicalOperator(node: bindings.TSNode, source: []const u8) ?[]const u8 {
    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        const ch = node.child(i);
        const slice = ch.slice(source);
        if (std.mem.eql(u8, slice, "and") or std.mem.eql(u8, slice, "or")) {
            return slice;
        }
    }
    return null;
}

fn findBinaryLogicalOperator(node: bindings.TSNode, source: []const u8) ?[]const u8 {
    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        const ch = node.child(i);
        const slice = ch.slice(source);
        if (std.mem.eql(u8, slice, "&&") or std.mem.eql(u8, slice, "||")) {
            return slice;
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

const GrammarHandle = struct {
    lang: Language,
    lib: std.DynLib,
    ts_language: *const bindings.TSLanguage,
};

var grammar_handles: std.ArrayList(GrammarHandle) = .empty;
const grammar_allocator = std.heap.page_allocator;

fn grammarLibraryName(lang: Language) ?[]const u8 {
    return switch (lang) {
        .go => "tree-sitter-go",
        .rust => "tree-sitter-rust",
        .python => "tree-sitter-python",
        .typescript => "tree-sitter-typescript",
        .tsx => "tree-sitter-tsx",
        .c_sharp => "tree-sitter-c_sharp",
        .zig => "tree-sitter-zig",
        .unknown => null,
    };
}

fn grammarSymbolName(lang: Language) ?[:0]const u8 {
    return switch (lang) {
        .go => "tree_sitter_go",
        .rust => "tree_sitter_rust",
        .python => "tree_sitter_python",
        .typescript => "tree_sitter_typescript",
        .tsx => "tree_sitter_tsx",
        .c_sharp => "tree_sitter_c_sharp",
        .zig => "tree_sitter_zig",
        .unknown => null,
    };
}

var grammar_mutex: std.atomic.Mutex = .unlocked;

fn lockGrammar() void {
    while (!grammar_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn unlockGrammar() void {
    grammar_mutex.unlock();
}

extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;

var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
var self_exe_dir: ?[]const u8 = null;

fn getSelfExeDir() ?[]const u8 {
    if (self_exe_dir) |dir| return dir;
    const rc = readlink("/proc/self/exe", &self_exe_buf, self_exe_buf.len);
    if (rc <= 0) return null;
    const exe_path = self_exe_buf[0..@intCast(rc)];
    const dir = std.fs.path.dirname(exe_path) orelse return null;
    self_exe_dir = dir;
    return dir;
}

fn loadGrammarLanguage(lang: Language) ?*const bindings.TSLanguage {
    if (lang == .unknown) return null;

    lockGrammar();
    defer unlockGrammar();

    // Check cache
    for (grammar_handles.items) |h| {
        if (h.lang == lang) return h.ts_language;
    }

    const lib_name = grammarLibraryName(lang) orelse return null;
    const sym_name = grammarSymbolName(lang) orelse return null;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var loaded: ?std.DynLib = null;

    // 1. Relative to binary ($ORIGIN/../lib)
    if (getSelfExeDir()) |exe_dir| {
        if (std.fmt.bufPrint(&path_buf, "{s}/../lib/lib{s}.so", .{ exe_dir, lib_name })) |p| {
            if (std.DynLib.open(p)) |lib| {
                loaded = lib;
            } else |_| {}
        } else |_| {}
    }

    // 2. Relative to cwd (dev)
    if (loaded == null) {
        if (std.fmt.bufPrint(&path_buf, "zig-out/lib/lib{s}.so", .{lib_name})) |p| {
            if (std.DynLib.open(p)) |lib| {
                loaded = lib;
            } else |_| {}
        } else |_| {}
    }

    // 3. System (/usr/lib)
    if (loaded == null) {
        if (std.fmt.bufPrint(&path_buf, "/usr/lib/lib{s}.so", .{lib_name})) |p| {
            if (std.DynLib.open(p)) |lib| {
                loaded = lib;
            } else |_| {}
        } else |_| {}
    }

    // 4. System (/usr/local/lib)
    if (loaded == null) {
        if (std.fmt.bufPrint(&path_buf, "/usr/local/lib/lib{s}.so", .{lib_name})) |p| {
            if (std.DynLib.open(p)) |lib| {
                loaded = lib;
            } else |_| {}
        } else |_| {}
    }

    var lib = loaded orelse return null;
    const sym = lib.lookup(*const fn () callconv(.c) ?*const bindings.TSLanguage, sym_name) orelse {
        lib.close();
        return null;
    };
    const ts_lang = sym() orelse {
        lib.close();
        return null;
    };

    grammar_handles.append(grammar_allocator, .{
        .lang = lang,
        .lib = lib,
        .ts_language = ts_lang,
    }) catch {
        lib.close();
        return null;
    };
    return ts_lang;
}
