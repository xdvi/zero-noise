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

pub fn analyzeBlastRadius(
    allocator: std.mem.Allocator,
    files: []const FileInput,
    symbol: []const u8,
) !BlastRadiusResult {
    var references: std.ArrayList(SymbolReference) = .empty;
    defer references.deinit(allocator);

    var files_with_usages = std.StringHashMap(void).init(allocator);
    defer files_with_usages.deinit();

    for (files) |file| {
        const file_refs = try scanFileReferences(allocator, file.path, file.content, symbol);
        defer allocator.free(file_refs);

        if (file_refs.len > 0) {
            try files_with_usages.put(file.path, {});
            for (file_refs) |ref| {
                try references.append(allocator, ref);
            }
        }
    }

    const files_count = files_with_usages.count();
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

                if (refs.items.len > 0) {
                    return refs.toOwnedSlice(allocator);
                }
            } else |_| {}
        }
    }

    return scanByLines(allocator, file_path, content, symbol);
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
    if (isIdentifierType(t)) {
        const text = node.slice(content);
        if (std.mem.eql(u8, text, symbol)) {
            const pt = node.startPoint();
            const snippet = getLineSnippet(content, pt.row);
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

fn isIdentifierType(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "identifier") or
        std.mem.eql(u8, node_type, "type_identifier") or
        std.mem.eql(u8, node_type, "field_identifier") or
        std.mem.eql(u8, node_type, "property_identifier") or
        std.mem.eql(u8, node_type, "shorthand_property_identifier");
}

fn checkIsDefinition(
    node: bindings.TSNode,
    lang: grammars.Language,
    snippet: []const u8,
    symbol: []const u8,
) bool {
    const parent = node.parent();
    if (!parent.isNull()) {
        const pt = parent.getType();
        const name_node = parent.childByFieldName("name");
        if (!name_node.isNull() and name_node.startByte() == node.startByte()) {
            if (std.mem.eql(u8, pt, "function_declaration") or
                std.mem.eql(u8, pt, "method_declaration") or
                std.mem.eql(u8, pt, "function_item") or
                std.mem.eql(u8, pt, "function_definition") or
                std.mem.eql(u8, pt, "method_definition") or
                std.mem.eql(u8, pt, "variable_declarator") or
                std.mem.eql(u8, pt, "class_declaration") or
                std.mem.eql(u8, pt, "struct_item") or
                std.mem.eql(u8, pt, "enum_item") or
                std.mem.eql(u8, pt, "trait_item") or
                std.mem.eql(u8, pt, "type_item") or
                std.mem.eql(u8, pt, "interface_declaration") or
                std.mem.eql(u8, pt, "type_alias_declaration") or
                std.mem.eql(u8, pt, "type_spec"))
            {
                return true;
            }
        }
    }

    return isDefinitionLineSnippet(snippet, symbol, lang);
}

fn isDefinitionLineSnippet(line: []const u8, symbol: []const u8, lang: grammars.Language) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    _ = lang;

    // Common definition keywords across Go, Python, TS, Rust, C#
    const prefixes = [_][]const u8{
        "func ", "def ", "class ", "interface ", "type ",
        "fn ", "struct ", "enum ", "const ", "let ", "var ",
        "public ", "private ", "protected ", "export ", "async def ",
    };

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            if (std.mem.indexOf(u8, trimmed, symbol) != null) {
                return true;
            }
        }
    }

    return false;
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

            // Ignore comment lines
            if (!isCommentLine(trimmed, lang)) {
                var search_pos: usize = 0;
                while (std.mem.indexOfPos(u8, line, search_pos, symbol)) |idx| {
                    if (isWordBoundary(line, idx, symbol.len)) {
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

fn getLineSnippet(source: []const u8, row: u32) []const u8 {
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
