const std = @import("std");

pub const TSLanguage = anyopaque;
pub const TSParser = anyopaque;
pub const TSTree = anyopaque;

pub const TSPoint = extern struct {
    row: u32,
    column: u32,
};

pub const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const anyopaque,

    pub fn getType(self: TSNode) [:0]const u8 {
        return std.mem.span(ts_node_type(self));
    }

    pub fn isNull(self: TSNode) bool {
        return ts_node_is_null(self);
    }

    pub fn isNamed(self: TSNode) bool {
        return ts_node_is_named(self);
    }

    pub fn hasError(self: TSNode) bool {
        return ts_node_has_error(self);
    }

    pub fn isError(self: TSNode) bool {
        return ts_node_is_error(self);
    }

    pub fn childCount(self: TSNode) u32 {
        return ts_node_child_count(self);
    }

    pub fn namedChildCount(self: TSNode) u32 {
        return ts_node_named_child_count(self);
    }

    pub fn child(self: TSNode, idx: u32) TSNode {
        return ts_node_child(self, idx);
    }

    pub fn namedChild(self: TSNode, idx: u32) TSNode {
        return ts_node_named_child(self, idx);
    }

    pub fn parent(self: TSNode) TSNode {
        return ts_node_parent(self);
    }

    pub fn startPoint(self: TSNode) TSPoint {
        return ts_node_start_point(self);
    }

    pub fn endPoint(self: TSNode) TSPoint {
        return ts_node_end_point(self);
    }

    pub fn startByte(self: TSNode) u32 {
        return ts_node_start_byte(self);
    }

    pub fn endByte(self: TSNode) u32 {
        return ts_node_end_byte(self);
    }

    pub fn slice(self: TSNode, source: []const u8) []const u8 {
        const start = self.startByte();
        const end = self.endByte();
        if (start >= source.len or end > source.len or start > end) return "";
        return source[start..end];
    }

    pub fn childByFieldName(self: TSNode, name: []const u8) TSNode {
        return ts_node_child_by_field_name(self, name.ptr, @intCast(name.len));
    }

    pub fn treeCursor(self: TSNode) TSTreeCursor {
        return ts_tree_cursor_new(self);
    }
};

pub const Parser = struct {
    handle: *TSParser,

    pub fn init() !Parser {
        const handle = ts_parser_new() orelse return error.ParserInitFailed;
        return Parser{ .handle = handle };
    }

    pub fn deinit(self: *Parser) void {
        ts_parser_delete(self.handle);
    }

    pub fn setLanguage(self: *Parser, lang: *const TSLanguage) bool {
        if (ts_parser_language(self.handle) == lang) return true;
        return ts_parser_set_language(self.handle, lang);
    }

    pub fn reset(self: *Parser) void {
        ts_parser_reset(self.handle);
    }

    pub fn parseString(self: *Parser, source: []const u8) !Tree {
        const tree_ptr = ts_parser_parse_string(self.handle, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
        return Tree{ .handle = tree_ptr };
    }
};

threadlocal var thread_parser: ?Parser = null;

pub fn getThreadParser() !*Parser {
    if (thread_parser == null) {
        thread_parser = try Parser.init();
    }
    return &thread_parser.?;
}

pub fn deinitThreadParser() void {
    if (thread_parser) |*p| {
        p.deinit();
        thread_parser = null;
    }
}


pub const Tree = struct {
    handle: *TSTree,

    pub fn deinit(self: *Tree) void {
        ts_tree_delete(self.handle);
    }

    pub fn rootNode(self: *const Tree) TSNode {
        return ts_tree_root_node(self.handle);
    }
};

pub const TSTreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,

    pub fn currentNode(self: *const TSTreeCursor) TSNode {
        return ts_tree_cursor_current_node(self);
    }

    pub fn gotoFirstChild(self: *TSTreeCursor) bool {
        return ts_tree_cursor_goto_first_child(self);
    }

    pub fn gotoNextSibling(self: *TSTreeCursor) bool {
        return ts_tree_cursor_goto_next_sibling(self);
    }

    pub fn gotoParent(self: *TSTreeCursor) bool {
        return ts_tree_cursor_goto_parent(self);
    }

    pub fn deinit(self: *TSTreeCursor) void {
        ts_tree_cursor_delete(self);
    }
};

pub extern "c" fn ts_parser_new() ?*TSParser;
pub extern "c" fn ts_parser_delete(parser: ?*TSParser) void;
pub extern "c" fn ts_parser_set_language(parser: ?*TSParser, language: ?*const TSLanguage) bool;
pub extern "c" fn ts_parser_language(parser: ?*const TSParser) ?*const TSLanguage;
pub extern "c" fn ts_parser_reset(parser: ?*TSParser) void;
pub extern "c" fn ts_parser_parse_string(parser: ?*TSParser, old_tree: ?*const TSTree, string: [*]const u8, length: u32) ?*TSTree;
pub extern "c" fn ts_tree_delete(tree: ?*TSTree) void;
pub extern "c" fn ts_tree_root_node(tree: ?*const TSTree) TSNode;

pub extern "c" fn ts_node_type(node: TSNode) [*:0]const u8;
pub extern "c" fn ts_node_is_null(node: TSNode) bool;
pub extern "c" fn ts_node_is_named(node: TSNode) bool;
pub extern "c" fn ts_node_has_error(node: TSNode) bool;
pub extern "c" fn ts_node_is_error(node: TSNode) bool;
pub extern "c" fn ts_node_child_count(node: TSNode) u32;
pub extern "c" fn ts_node_named_child_count(node: TSNode) u32;
pub extern "c" fn ts_node_child(node: TSNode, index: u32) TSNode;
pub extern "c" fn ts_node_named_child(node: TSNode, index: u32) TSNode;
pub extern "c" fn ts_node_child_by_field_name(node: TSNode, name: [*]const u8, length: u32) TSNode;
pub extern "c" fn ts_node_parent(node: TSNode) TSNode;
pub extern "c" fn ts_node_start_point(node: TSNode) TSPoint;
pub extern "c" fn ts_node_end_point(node: TSNode) TSPoint;
pub extern "c" fn ts_node_start_byte(node: TSNode) u32;
pub extern "c" fn ts_node_end_byte(node: TSNode) u32;

pub extern "c" fn ts_tree_cursor_new(node: TSNode) TSTreeCursor;
pub extern "c" fn ts_tree_cursor_delete(cursor: *const TSTreeCursor) void;
pub extern "c" fn ts_tree_cursor_current_node(cursor: *const TSTreeCursor) TSNode;
pub extern "c" fn ts_tree_cursor_goto_first_child(cursor: *TSTreeCursor) bool;
pub extern "c" fn ts_tree_cursor_goto_next_sibling(cursor: *TSTreeCursor) bool;
pub extern "c" fn ts_tree_cursor_goto_parent(cursor: *TSTreeCursor) bool;

pub extern "c" fn tree_sitter_go() ?*const TSLanguage;
pub extern "c" fn tree_sitter_rust() ?*const TSLanguage;
pub extern "c" fn tree_sitter_python() ?*const TSLanguage;
pub extern "c" fn tree_sitter_typescript() ?*const TSLanguage;
pub extern "c" fn tree_sitter_tsx() ?*const TSLanguage;
pub extern "c" fn tree_sitter_c_sharp() ?*const TSLanguage;
pub extern "c" fn tree_sitter_zig() ?*const TSLanguage;

test "tree sitter error detection" {
    var parser = try Parser.init();
    defer parser.deinit();
    const grammars = @import("grammars.zig");
    const ts_lang = grammars.Language.typescript.getTsLanguage().?;
    _ = parser.setLanguage(ts_lang);

    var valid_tree = try parser.parseString("const x = 10;");
    defer valid_tree.deinit();
    try std.testing.expect(!valid_tree.rootNode().hasError());

    var invalid_tree = try parser.parseString("const x = ;");
    defer invalid_tree.deinit();
    try std.testing.expect(invalid_tree.rootNode().hasError());
}

test "reusable thread parser parses and switches languages cleanly" {
    const grammars = @import("grammars.zig");
    const ts_lang = grammars.Language.typescript.getTsLanguage().?;
    const go_lang = grammars.Language.go.getTsLanguage().?;

    var p = try getThreadParser();
    defer deinitThreadParser();

    try std.testing.expect(p.setLanguage(ts_lang));
    var tree_ts = try p.parseString("function add(a: number, b: number): number { return a + b; }");
    defer tree_ts.deinit();
    try std.testing.expect(!tree_ts.rootNode().hasError());

    // Switch language on the same parser instance without reallocating
    try std.testing.expect(p.setLanguage(go_lang));
    var tree_go = try p.parseString("package main\nfunc add(a int, b int) int { return a + b }");
    defer tree_go.deinit();
    try std.testing.expect(!tree_go.rootNode().hasError());
}

test "tree cursor traversal" {
    const grammars = @import("grammars.zig");
    const ts_lang = grammars.Language.typescript.getTsLanguage().?;
    var p = try getThreadParser();
    defer deinitThreadParser();

    try std.testing.expect(p.setLanguage(ts_lang));
    var tree = try p.parseString("const a = 1; const b = 2;");
    defer tree.deinit();

    var cursor = tree.rootNode().treeCursor();
    defer cursor.deinit();

    try std.testing.expect(cursor.gotoFirstChild());
    const first = cursor.currentNode();
    try std.testing.expectEqualStrings("lexical_declaration", first.getType());

    try std.testing.expect(cursor.gotoNextSibling());
    const second = cursor.currentNode();
    try std.testing.expectEqualStrings("lexical_declaration", second.getType());

    try std.testing.expect(!cursor.gotoNextSibling());
    try std.testing.expect(cursor.gotoParent());
    try std.testing.expectEqualStrings("program", cursor.currentNode().getType());
}


