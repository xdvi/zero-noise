const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const RiskLevel = enum {
    low,
    medium,
    high,

    pub fn asString(self: RiskLevel) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const SymbolReference = struct {
    file: []const u8,
    line: u32,
    column: u32,
    is_definition: bool,
    snippet: []const u8,
};

pub const BlastRadiusResult = struct {
    symbol: []const u8,
    risk: RiskLevel,
    total_usages: u32,
    files_count: u32,
    references: []SymbolReference,

    pub fn deinit(self: *BlastRadiusResult, allocator: std.mem.Allocator) void {
        allocator.free(self.references);
    }
};

pub const FileInput = struct {
    path: []const u8,
    content: []const u8,
};

pub fn calculateRisk(files_count: u32) RiskLevel {
    if (files_count <= 1) return .low;
    if (files_count <= 3) return .medium;
    return .high;
}

pub const ParsedFile = struct {
    path: []const u8,
    content: []const u8,
    lang: grammars.Language,
    tree: ?bindings.Tree = null,

    pub fn deinit(self: *ParsedFile) void {
        if (self.tree) |*t| {
            t.deinit();
            self.tree = null;
        }
    }
};

pub fn parseFileInputs(allocator: std.mem.Allocator, files: []const FileInput) ![]ParsedFile {
    const list = try allocator.alloc(ParsedFile, files.len);
    errdefer allocator.free(list);

    for (files, 0..) |f, i| {
        list[i] = parseOneFile(f);
    }
    return list;
}

pub fn deinitParsedFiles(allocator: std.mem.Allocator, files: []ParsedFile) void {
    for (files) |*f| {
        f.deinit();
    }
    allocator.free(files);
}

pub fn scanParsedFileReferences(
    allocator: std.mem.Allocator,
    file: *const ParsedFile,
    symbol: []const u8,
) ![]SymbolReference {
    if (file.content.len == 0 or symbol.len == 0) return &.{};
    if (std.mem.indexOf(u8, file.content, symbol) == null) return &.{};

    if (file.tree) |tree| {
        var refs: std.ArrayList(SymbolReference) = .empty;
        defer refs.deinit(allocator);

        try walkTreeForSymbol(
            allocator,
            tree.rootNode(),
            file.path,
            file.content,
            symbol,
            file.lang,
            &refs,
        );

        return refs.toOwnedSlice(allocator);
    }

    return scanByLines(allocator, file.path, file.content, symbol);
}

pub fn analyzeBlastRadiusParsed(
    allocator: std.mem.Allocator,
    files: []const ParsedFile,
    symbol: []const u8,
) !BlastRadiusResult {
    var references: std.ArrayList(SymbolReference) = .empty;
    defer references.deinit(allocator);

    var files_with_usages = std.StringHashMap(void).init(allocator);
    defer files_with_usages.deinit();

    for (files) |*file| {
        const file_refs = try scanParsedFileReferences(allocator, file, symbol);
        defer allocator.free(file_refs);

        if (file_refs.len > 0) {
            try files_with_usages.put(file.path, {});
            for (file_refs) |ref| {
                try references.append(allocator, ref);
            }
        }
    }

    const files_count: u32 = @intCast(files_with_usages.count());
    const total_usages: u32 = @intCast(references.items.len);
    const risk = calculateRisk(files_count);

    return BlastRadiusResult{
        .symbol = symbol,
        .risk = risk,
        .total_usages = total_usages,
        .files_count = files_count,
        .references = try references.toOwnedSlice(allocator),
    };
}

pub fn analyzeBlastRadius(
    allocator: std.mem.Allocator,
    files: []const FileInput,
    symbol: []const u8,
) !BlastRadiusResult {
    const parsed = try parseFileInputs(allocator, files);
    defer deinitParsedFiles(allocator, parsed);
    return analyzeBlastRadiusParsed(allocator, parsed, symbol);
}

pub fn scanFileReferences(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    symbol: []const u8,
) ![]SymbolReference {
    if (content.len == 0 or symbol.len == 0) return &.{};
    if (std.mem.indexOf(u8, content, symbol) == null) return &.{};

    const lang = grammars.Language.fromPath(file_path);
    const ts_lang = lang.getTsLanguage();

    if (ts_lang) |tl| {
        var parser = bindings.Parser.init() catch return scanByLines(allocator, file_path, content, symbol);
        defer parser.deinit();

        if (parser.setLanguage(tl)) {
            if (parser.parseString(content)) |tree| {
                var mutable_tree = tree;
                defer mutable_tree.deinit();

                var refs: std.ArrayList(SymbolReference) = .empty;
                defer refs.deinit(allocator);

                try walkTreeForSymbol(
                    allocator,
                    tree.rootNode(),
                    file_path,
                    content,
                    symbol,
                    lang,
                    &refs,
                );

                return refs.toOwnedSlice(allocator);
            } else |_| {}
        }
    }

    return scanByLines(allocator, file_path, content, symbol);
}

fn isStructFieldDeclaration(node: bindings.TSNode) bool {
    const parent = node.parent();
    if (parent.isNull()) return false;
    const pt = parent.getType();
    if (std.mem.eql(u8, pt, "field_declaration") or
        std.mem.eql(u8, pt, "property_signature") or
        std.mem.eql(u8, pt, "field_definition") or
        std.mem.eql(u8, pt, "public_field_definition") or
        std.mem.eql(u8, pt, "property_definition") or
        std.mem.eql(u8, pt, "property_declaration"))
    {
        const name_node = parent.childByFieldName("name");
        if (!name_node.isNull()) {
            return name_node.startByte() == node.startByte() and name_node.endByte() == node.endByte();
        }
        if (parent.childCount() > 0) {
            const first = parent.child(0);
            return first.startByte() == node.startByte() and first.endByte() == node.endByte();
        }
        return true;
    }
    return false;
}

fn isStructFieldAccess(node: bindings.TSNode) bool {
    const parent = node.parent();
    if (parent.isNull()) return false;
    const pt = parent.getType();
    if (std.mem.eql(u8, pt, "selector_expression") or
        std.mem.eql(u8, pt, "field_expression") or
        std.mem.eql(u8, pt, "member_expression") or
        std.mem.eql(u8, pt, "member_access_expression"))
    {
        const field_node = parent.childByFieldName("field");
        if (!field_node.isNull()) {
            return field_node.startByte() == node.startByte() and field_node.endByte() == node.endByte();
        }
        const prop_node = parent.childByFieldName("property");
        if (!prop_node.isNull()) {
            return prop_node.startByte() == node.startByte() and prop_node.endByte() == node.endByte();
        }
        const attr_node = parent.childByFieldName("attribute");
        if (!attr_node.isNull()) {
            return attr_node.startByte() == node.startByte() and attr_node.endByte() == node.endByte();
        }
        const name_node = parent.childByFieldName("name");
        if (!name_node.isNull()) {
            return name_node.startByte() == node.startByte() and name_node.endByte() == node.endByte();
        }
        return true;
    }
    return false;
}

fn walkTreeForSymbol(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    file_path: []const u8,
    content: []const u8,
    symbol: []const u8,
    lang: grammars.Language,
    refs: *std.ArrayList(SymbolReference),
) !void {
    if (node.isNull()) return;

    const t = node.getType();
    if (grammars.isIdentifierType(t)) {
        if (isStructFieldDeclaration(node)) {
            return;
        }
        const text = node.slice(content);
        if (std.mem.eql(u8, text, symbol)) {
            const pt = node.startPoint();
            const snippet = grammars.getLineSnippet(content, pt.row);
            const is_def = checkIsDefinition(node, lang, snippet, symbol);

            try refs.append(allocator, .{
                .file = file_path,
                .line = pt.row + 1,
                .column = pt.column + 1,
                .is_definition = is_def,
                .snippet = snippet,
            });
            return;
        }
    }

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try walkTreeForSymbol(allocator, node.child(i), file_path, content, symbol, lang, refs);
    }
}

fn checkIsDefinition(
    node: bindings.TSNode,
    lang: grammars.Language,
    snippet: []const u8,
    symbol: []const u8,
) bool {
    if (isStructFieldDeclaration(node) or isStructFieldAccess(node)) {
        return false;
    }

    const parent = node.parent();
    if (!parent.isNull()) {
        if (isDefinitionParent(parent, node)) |result| return result;
    }

    return isDefinitionLineSnippet(snippet, symbol, lang);
}

fn isDefinitionLineSnippet(line: []const u8, symbol: []const u8, lang: grammars.Language) bool {
    _ = lang;
    var rest = std.mem.trim(u8, line, " \t\r");

    rest = stripModifiers(rest);

    const decl_keywords = [_][]const u8{
        "func ", "function ", "def ",  "class ", "interface ", "type ",
        "fn ",   "struct ",   "enum ", "trait ", "const ",     "let ",
        "var ",
    };
    var matched = false;
    for (decl_keywords) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) {
            rest = std.mem.trim(u8, rest[kw.len..], " \t\r");
            matched = true;
            break;
        }
    }
    if (!matched) return false;

    if (std.mem.startsWith(u8, rest, "mut ")) {
        rest = std.mem.trim(u8, rest[4..], " \t\r");
    }

    if (std.mem.startsWith(u8, rest, "(")) {
        if (std.mem.indexOf(u8, rest, ")")) |close_paren| {
            rest = std.mem.trim(u8, rest[close_paren + 1 ..], " \t\r");
        }
    }

    var decl_end: usize = rest.len;
    for (rest, 0..) |c, idx| {
        if (c == '=' or c == ':' or c == '(' or c == '{' or c == ';' or c == '<') {
            decl_end = idx;
            break;
        }
    }
    const decl_part = rest[0..decl_end];

    return containsWord(decl_part, symbol);
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |idx| {
        if (isWordBoundary(haystack, idx, needle.len)) {
            return true;
        }
        pos = idx + needle.len;
    }
    return false;
}


fn isInsideStringLiteral(line: []const u8, idx: usize) bool {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < idx and i < line.len) {
        const step = advanceStringState(line, i, in_single, in_double);
        i = step.next_i;
        in_single = step.in_single;
        in_double = step.in_double;
    }
    return in_single or in_double;
}

const StringState = struct { next_i: usize, in_single: bool, in_double: bool };

fn advanceStringState(line: []const u8, i: usize, in_single: bool, in_double: bool) StringState {
    if (in_double) {
        if (line[i] == '\\' and i + 1 < line.len) {
            return .{ .next_i = i + 2, .in_single = in_single, .in_double = in_double };
        }
        if (line[i] == '"') {
            return .{ .next_i = i + 1, .in_single = in_single, .in_double = false };
        }
        return .{ .next_i = i + 1, .in_single = in_single, .in_double = in_double };
    }
    if (in_single) {
        if (line[i] == '\\' and i + 1 < line.len) {
            return .{ .next_i = i + 2, .in_single = in_single, .in_double = in_double };
        }
        if (line[i] == '\'') {
            return .{ .next_i = i + 1, .in_single = false, .in_double = in_double };
        }
        return .{ .next_i = i + 1, .in_single = in_single, .in_double = in_double };
    }
    if (line[i] == '"') {
        return .{ .next_i = i + 1, .in_single = false, .in_double = true };
    }
    if (line[i] == '\'') {
        return .{ .next_i = i + 1, .in_single = true, .in_double = false };
    }
    return .{ .next_i = i + 1, .in_single = in_single, .in_double = in_double };
}

fn scanByLines(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    symbol: []const u8,
) ![]SymbolReference {
    var refs: std.ArrayList(SymbolReference) = .empty;
    defer refs.deinit(allocator);

    var line_no: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;

    const lang = grammars.Language.fromPath(file_path);

    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            const line = content[line_start..i];
            const trimmed = std.mem.trim(u8, line, " \t\r");
            try processScanLine(allocator, file_path, line, trimmed, symbol, lang, line_no, &refs);
            line_no += 1;
            line_start = i + 1;
        }
    }

    return refs.toOwnedSlice(allocator);
}

fn isCommentLine(line: []const u8, lang: grammars.Language) bool {
    if (line.len == 0) return true;
    _ = lang;
    return std.mem.startsWith(u8, line, "//") or
        std.mem.startsWith(u8, line, "/*") or
        std.mem.startsWith(u8, line, "*") or
        std.mem.startsWith(u8, line, "#");
}

fn isWordBoundary(line: []const u8, pos: usize, len: usize) bool {
    if (pos > 0) {
        const prev = line[pos - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_') return false;
    }
    if (pos + len < line.len) {
        const next = line[pos + len];
        if (std.ascii.isAlphanumeric(next) or next == '_') return false;
    }
    return true;
}

test "analyzeBlastRadius - single file definition and usage" {
    const file_content =
        \\package main
        \\
        \\func ProcessItem(x int) int {
        \\    return ProcessItem(x - 1)
        \\}
    ;

    const files = [_]FileInput{
        .{ .path = "main.go", .content = file_content },
    };

    var res = try analyzeBlastRadius(std.testing.allocator, &files, "ProcessItem");
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ProcessItem", res.symbol);
    try std.testing.expectEqual(RiskLevel.low, res.risk);
    try std.testing.expectEqual(@as(u32, 1), res.files_count);
    try std.testing.expectEqual(@as(u32, 2), res.total_usages);

    // First is definition, second is recursive call
    try std.testing.expect(res.references[0].is_definition);
    try std.testing.expect(!res.references[1].is_definition);
}

test "analyzeBlastRadius - risk level calculation across multiple files" {
    const f1 = "export function AuthToken() { return 'secret'; }";
    const f2 = "import { AuthToken } from './f1'; const t = AuthToken();";
    const f3 = "const userToken = AuthToken();";
    const f4 = "if (AuthToken()) { console.log('ok'); }";

    const files_medium = [_]FileInput{
        .{ .path = "f1.ts", .content = f1 },
        .{ .path = "f2.ts", .content = f2 },
    };

    var res_med = try analyzeBlastRadius(std.testing.allocator, &files_medium, "AuthToken");
    defer res_med.deinit(std.testing.allocator);

    try std.testing.expectEqual(RiskLevel.medium, res_med.risk);
    try std.testing.expectEqual(@as(u32, 2), res_med.files_count);

    const files_high = [_]FileInput{
        .{ .path = "f1.ts", .content = f1 },
        .{ .path = "f2.ts", .content = f2 },
        .{ .path = "f3.ts", .content = f3 },
        .{ .path = "f4.ts", .content = f4 },
    };

    var res_high = try analyzeBlastRadius(std.testing.allocator, &files_high, "AuthToken");
    defer res_high.deinit(std.testing.allocator);

    try std.testing.expectEqual(RiskLevel.high, res_high.risk);
    try std.testing.expectEqual(@as(u32, 4), res_high.files_count);
}

test "analyzeBlastRadius - comments ignored in line scanner" {
    const content =
        \\# AuthToken is an important symbol
        \\def AuthToken():
        \\    pass
    ;

    const files = [_]FileInput{
        .{ .path = "auth.unknown_ext", .content = content },
    };

    var res = try analyzeBlastRadius(std.testing.allocator, &files, "AuthToken");
    defer res.deinit(std.testing.allocator);

    // Only the def line, not the comment line
    try std.testing.expectEqual(@as(u32, 1), res.total_usages);
    try std.testing.expect(res.references[0].is_definition);
}

test "scanFileReferences - AST scan does not fallback to lines when zero refs found" {
    const content =
        \\// FooSymbol mentioned in comment
        \\const s = "FooSymbol in string";
    ;

    const refs = try scanFileReferences(std.testing.allocator, "test.ts", content, "FooSymbol");
    defer std.testing.allocator.free(refs);

    // Tree-sitter parsed successfully, so FooSymbol in comments/strings must NOT be returned
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "scanFileReferences - definition accuracy on variable assignment" {
    const content =
        \\const x = foo();
    ;

    const refs = try scanFileReferences(std.testing.allocator, "test.ts", content, "foo");
    defer std.testing.allocator.free(refs);

    try std.testing.expectEqual(@as(usize, 1), refs.len);
    // foo is a call target / value, NOT a definition!
    try std.testing.expect(!refs[0].is_definition);
}

test "scanFileReferences - line scanner definition accuracy on variable assignment" {
    const content =
        \\const x = foo();
    ;

    const refs = try scanFileReferences(std.testing.allocator, "test.unknown", content, "foo");
    defer std.testing.allocator.free(refs);

    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expect(!refs[0].is_definition);
}

test "scanFileReferences - line scanner definition accuracy for actual declared symbol" {
    const content =
        \\const x = foo();
    ;

    const refs = try scanFileReferences(std.testing.allocator, "test.unknown", content, "x");
    defer std.testing.allocator.free(refs);

    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expect(refs[0].is_definition);
}

test "scanFileReferences - struct field declarations ignored as false positives" {
    const ts_content =
        \\interface Config {
        \\    worker: number;
        \\}
        \\class Service {
        \\    worker: string;
        \\}
    ;

    const refs = try scanFileReferences(std.testing.allocator, "config.ts", ts_content, "worker");
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(@as(usize, 0), refs.len);

    const go_content =
        \\package main
        \\type Config struct {
        \\    Worker int
        \\}
    ;

    const go_refs = try scanFileReferences(std.testing.allocator, "config.go", go_content, "Worker");
    defer std.testing.allocator.free(go_refs);
    try std.testing.expectEqual(@as(usize, 0), go_refs.len);
}

test "scanFileReferences - struct field access is not marked as definition" {
    const content =
        \\function update(cfg) {
        \\    cfg.worker = 42;
        \\}
    ;

    const refs = try scanFileReferences(std.testing.allocator, "update.ts", content, "worker");
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expect(!refs[0].is_definition);
}

test "analyzeBlastRadiusParsed - reuses ASTs across multiple symbol queries" {
    const files = [_]FileInput{
        .{ .path = "svc.go", .content = "package main\n\nfunc Alpha() {}\nfunc Beta() { Alpha() }\n" },
    };

    const parsed = try parseFileInputs(std.testing.allocator, &files);
    defer deinitParsedFiles(std.testing.allocator, parsed);

    try std.testing.expect(parsed[0].tree != null);

    const res_alpha = try analyzeBlastRadiusParsed(std.testing.allocator, parsed, "Alpha");
    var a = res_alpha;
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), a.total_usages);

    const res_beta = try analyzeBlastRadiusParsed(std.testing.allocator, parsed, "Beta");
    var b = res_beta;
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), b.total_usages);
}

fn parseOneFile(f: FileInput) ParsedFile {
    const lang = grammars.Language.fromPath(f.path);
    var parsed_tree: ?bindings.Tree = null;
    if (lang.getTsLanguage()) |tl| {
        if (bindings.Parser.init()) |parser_inst| {
            var parser = parser_inst;
            defer parser.deinit();
            if (parser.setLanguage(tl)) {
                parsed_tree = parser.parseString(f.content) catch null;
            }
        } else |_| {}
    }
    return .{
        .path = f.path,
        .content = f.content,
        .lang = lang,
        .tree = parsed_tree,
    };
}

fn isDefinitionParent(parent: bindings.TSNode, node: bindings.TSNode) ?bool {
    const pt = parent.getType();
    const name_node = parent.childByFieldName("name");
    if (!name_node.isNull() and name_node.startByte() == node.startByte()) {
        if (isDefinitionParentType(pt)) return true;
    }
    if (std.mem.eql(u8, pt, "let_declaration")) {
        const pattern = parent.childByFieldName("pattern");
        if (!pattern.isNull() and node.startByte() >= pattern.startByte() and node.endByte() <= pattern.endByte()) {
            return true;
        }
    }
    if (std.mem.eql(u8, pt, "assignment")) {
        const left = parent.childByFieldName("left");
        if (!left.isNull() and node.startByte() >= left.startByte() and node.endByte() <= left.endByte()) {
            return true;
        }
    }
    if (std.mem.eql(u8, pt, "short_var_decl")) {
        const left = parent.childByFieldName("left");
        if (!left.isNull() and node.startByte() >= left.startByte() and node.endByte() <= left.endByte()) {
            return true;
        }
    }
    if (isNonDefinitionParentType(pt)) return false;
    return null;
}

fn isDefinitionParentType(pt: []const u8) bool {
    const types = [_][]const u8{
        "function_declaration", "method_declaration", "function_item",
        "function_definition",  "method_definition", "variable_declarator",
        "class_declaration",    "class_definition",  "struct_item",
        "enum_item",            "trait_item",       "type_item",
        "interface_declaration", "type_alias_declaration", "type_spec",
    };
    for (types) |t| {
        if (std.mem.eql(u8, pt, t)) return true;
    }
    return false;
}

fn isNonDefinitionParentType(pt: []const u8) bool {
    const types = [_][]const u8{
        "call_expression", "arguments", "argument_list",
        "binary_expression", "unary_expression", "return_statement",
    };
    for (types) |t| {
        if (std.mem.eql(u8, pt, t)) return true;
    }
    return false;
}

fn stripModifiers(rest_in: []const u8) []const u8 {
    const modifiers = [_][]const u8{
        "export default ", "export ", "public ", "private ",    "protected ",
        "internal ",       "static ", "async ",  "pub(crate) ", "pub(super) ",
        "pub ",
    };
    var rest = rest_in;
    var stripped = true;
    while (stripped) {
        stripped = false;
        for (modifiers) |m| {
            if (std.mem.startsWith(u8, rest, m)) {
                rest = std.mem.trim(u8, rest[m.len..], " \t\r");
                stripped = true;
                break;
            }
        }
    }
    return rest;
}

fn processScanLine(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    line: []const u8,
    trimmed: []const u8,
    symbol: []const u8,
    lang: grammars.Language,
    line_no: u32,
    refs: *std.ArrayList(SymbolReference),
) !void {
    if (isCommentLine(trimmed, lang)) return;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_pos, symbol)) |idx| {
        if (!isInsideStringLiteral(line, idx) and isWordBoundary(line, idx, symbol.len)) {
            const snippet = trimmed;
            const is_def = isDefinitionLineSnippet(snippet, symbol, lang);
            try refs.append(allocator, .{
                .file = file_path,
                .line = line_no,
                .column = @intCast(idx + 1),
                .is_definition = is_def,
                .snippet = snippet,
            });
        }
        search_pos = idx + symbol.len;
    }
}
