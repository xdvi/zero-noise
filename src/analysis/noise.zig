const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const NoiseRule = enum {
    excessive_nesting,
    long_closure,
    redundant_ternary,
    repeated_literal,
    raw_boolean,
    commented_code,

    pub fn asString(self: NoiseRule) []const u8 {
        return switch (self) {
            .excessive_nesting => "excessive-nesting",
            .long_closure => "long-closure",
            .redundant_ternary => "redundant-ternary",
            .repeated_literal => "repeated-literal",
            .raw_boolean => "raw-boolean",
            .commented_code => "commented-code",
        };
    }
};

pub const NoiseFinding = struct {
    rule: NoiseRule,
    line: u32,
    column: u32,
    message: []const u8,
    snippet: []const u8 = "",
};

pub const NoiseConfig = struct {
    max_nesting: u32 = 2,
    max_closure_len: u32 = 80,
};

pub fn auditNoise(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) ![]NoiseFinding {
    return auditNoiseWithOptions(allocator, source, lang, .{});
}

pub fn auditNoiseWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    config: NoiseConfig,
) ![]NoiseFinding {
    const ts_lang = lang.getTsLanguage() orelse return &.{};

    var parser = try bindings.Parser.init();
    defer parser.deinit();

    if (!parser.setLanguage(ts_lang)) return error.SetLanguageFailed;

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const root = tree.rootNode();
    var findings: std.ArrayList(NoiseFinding) = .empty;
    defer findings.deinit(allocator);
    errdefer {
        for (findings.items) |f| {
            if (f.rule == .repeated_literal) allocator.free(f.message);
        }
    }

    // 1. AST walk for structural nesting, closures, redundant ternaries, and raw booleans
    try walkNoise(allocator, root, source, lang, 0, config, &findings);

    // 2. Scan repeated string literals
    try collectRepeatedLiterals(allocator, root, source, &findings);

    // 3. Scan commented-out code blocks
    try collectCommentedCode(allocator, root, source, &findings);

    return findings.toOwnedSlice(allocator);
}

pub fn deinitFindings(allocator: std.mem.Allocator, findings: []NoiseFinding) void {
    for (findings) |f| {
        if (f.rule == .repeated_literal) {
            allocator.free(f.message);
            allocator.free(f.snippet);
        }
    }
    if (findings.len > 0) {
        allocator.free(findings);
    }
}

fn isArrowFunctionAssignedToVariable(node: bindings.TSNode) bool {
    const t = node.getType();
    if (std.mem.eql(u8, t, "arrow_function") or std.mem.eql(u8, t, "function_expression")) {
        const p = node.parent();
        if (!p.isNull() and std.mem.eql(u8, p.getType(), "variable_declarator")) {
            return true;
        }
    }
    return false;
}

fn isInsideCallArguments(node: bindings.TSNode) bool {
    var curr = node.parent();
    while (!curr.isNull()) {
        const pt = curr.getType();
        if (std.mem.eql(u8, pt, "arguments") or std.mem.eql(u8, pt, "argument_list")) {
            return true;
        }
        if (std.mem.eql(u8, pt, "statement_block") or
            std.mem.eql(u8, pt, "block") or
            std.mem.eql(u8, pt, "function_declaration") or
            std.mem.eql(u8, pt, "function_definition") or
            std.mem.eql(u8, pt, "method_definition") or
            std.mem.eql(u8, pt, "variable_declarator"))
        {
            return false;
        }
        curr = curr.parent();
    }
    return false;
}

fn countLogicalOperators(node: bindings.TSNode, source: []const u8, lang: grammars.Language) u32 {
    if (node.isNull()) return 0;
    const t = node.getType();

    if (std.mem.eql(u8, t, "call_expression") or
        std.mem.eql(u8, t, "call") or
        std.mem.eql(u8, t, "invocation_expression") or
        lang.isClosure(t) or
        lang.isFunction(t))
    {
        return 0;
    }

    var count: u32 = 0;
    if (grammars.getLogicalOperator(node, source, lang) != null) {
        count += 1;
    }

    var i: u32 = 0;
    const child_count = node.childCount();
    while (i < child_count) : (i += 1) {
        count += countLogicalOperators(node.child(i), source, lang);
    }
    return count;
}

fn walkNoise(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    source: []const u8,
    lang: grammars.Language,
    depth: u32,
    config: NoiseConfig,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    if (node.isNull()) return;

    const t = node.getType();
    var next_depth = depth;

    // Reset nesting depth at function boundaries
    if (lang.isFunctionNode(node) or isArrowFunctionAssignedToVariable(node) or lang.isClosure(t)) {
        next_depth = 0;
    } else if (lang.isControl(t)) {
        const is_elif = lang.isElseIfNode(node);
        if (!is_elif) {
            next_depth = depth + 1;
            try checkExcessiveNesting(allocator, node, next_depth, config, source, findings);
        }
    }

    try checkLongClosure(allocator, node, lang, config, source, findings);
    try checkRedundantTernaryFinding(allocator, node, lang, source, findings);
    try checkRawBoolean(allocator, node, lang, source, findings);

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try walkNoise(allocator, node.child(i), source, lang, next_depth, config, findings);
    }
}

fn isRedundantTernary(node: bindings.TSNode, source: []const u8, lang: grammars.Language) bool {
    var cons_node: bindings.TSNode = undefined;
    var alt_node: bindings.TSNode = undefined;

    switch (lang) {
        .python => {
            cons_node = node.childByFieldName("body");
            if (cons_node.isNull()) cons_node = node.childByFieldName("consequence");
            if (cons_node.isNull()) {
                if (node.namedChildCount() >= 2) {
                    cons_node = node.namedChild(0);
                } else if (node.childCount() >= 1) {
                    cons_node = node.child(0);
                }
            }

            alt_node = node.childByFieldName("alternative");
            if (alt_node.isNull()) {
                if (node.namedChildCount() >= 3) {
                    alt_node = node.namedChild(2);
                } else if (node.childCount() >= 5) {
                    alt_node = node.child(node.childCount() - 1);
                }
            }
        },
        .rust => {
            const cons_raw = node.childByFieldName("consequence");
            cons_node = unwrapRustBlock(cons_raw);

            const alt_raw = node.childByFieldName("alternative");
            alt_node = unwrapRustBlock(alt_raw);
        },
        else => {
            cons_node = node.childByFieldName("consequence");
            alt_node = node.childByFieldName("alternative");
        },
    }

    if (cons_node.isNull() or alt_node.isNull()) return false;

    const cons_val = getBooleanLiteralValue(cons_node, source) orelse return false;
    const alt_val = getBooleanLiteralValue(alt_node, source) orelse return false;
    return cons_val != alt_val;
}

fn unwrapRustBlock(node: bindings.TSNode) bindings.TSNode {
    if (node.isNull()) return node;
    const t = node.getType();
    if (std.mem.eql(u8, t, "else_clause")) return unwrapRustElseClause(node);
    if (std.mem.eql(u8, t, "block")) return unwrapRustBlockNode(node);
    return node;
}

fn unwrapRustElseClause(node: bindings.TSNode) bindings.TSNode {
    const alt = node.childByFieldName("alternative");
    if (!alt.isNull()) return unwrapRustBlock(alt);
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const ch = node.namedChild(i);
        if (std.mem.eql(u8, ch.getType(), "block") or std.mem.eql(u8, ch.getType(), "if_expression")) {
            return unwrapRustBlock(ch);
        }
    }
    return node;
}

fn unwrapRustBlockNode(node: bindings.TSNode) bindings.TSNode {
    if (node.namedChildCount() == 1) {
        return unwrapRustBlock(node.namedChild(0));
    }
    if (node.namedChildCount() == 0) return node;
    const last = node.namedChild(node.namedChildCount() - 1);
    if (std.mem.eql(u8, last.getType(), "expression_statement") and last.namedChildCount() == 1) {
        return unwrapRustBlock(last.namedChild(0));
    }
    return node;
}

fn getBooleanLiteralValue(node: bindings.TSNode, source: []const u8) ?bool {
    if (node.isNull()) return null;
    const text = std.mem.trim(u8, node.slice(source), " \t\r\n;");
    const t = node.getType();

    if (std.mem.eql(u8, t, "true")) return true;
    if (std.mem.eql(u8, t, "false")) return false;
    if (std.mem.eql(u8, t, "boolean_literal")) {
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "True")) return true;
        if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "False")) return false;
        return null;
    }

    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "True")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "False")) return false;

    return null;
}

const LiteralOccur = struct {
    count: u32,
    line: u32,
    col: u32,
};

fn collectRepeatedLiterals(
    allocator: std.mem.Allocator,
    root: bindings.TSNode,
    source: []const u8,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    var literal_map = std.StringHashMap(LiteralOccur).init(allocator);
    defer {
        var kit = literal_map.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        literal_map.deinit();
    }

    try scanLiterals(allocator, root, source, &literal_map);

    var it = literal_map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.count >= 3) {
            const msg = try std.fmt.allocPrint(allocator, "literal '{s}' repeated {d} times (DRY candidate)", .{
                entry.key_ptr.*,
                entry.value_ptr.count,
            });
            try findings.append(allocator, .{
                .rule = .repeated_literal,
                .line = entry.value_ptr.line,
                .column = entry.value_ptr.col,
                .message = msg,
                .snippet = try allocator.dupe(u8, entry.key_ptr.*),
            });
        }
    }
}

fn cleanCommentLine(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, s, "///")) {
        s = s[3..];
    } else if (std.mem.startsWith(u8, s, "//")) {
        s = s[2..];
    } else if (std.mem.startsWith(u8, s, "/*")) {
        s = s[2..];
    } else if (std.mem.startsWith(u8, s, "*")) {
        s = s[1..];
    } else if (std.mem.startsWith(u8, s, "#")) {
        s = s[1..];
    }
    if (std.mem.endsWith(u8, s, "*/")) {
        s = s[0 .. s.len - 2];
    }
    return std.mem.trim(u8, s, " \t\r");
}

fn isCodeLine(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;

    const code_prefixes = [_][]const u8{
        "if ",     "if(",      "elif ",      "elif(",     "else if",   "else {",    "else:",
        "for ",    "for(",     "while ",     "while(",    "do {",      "switch ",   "switch(",
        "case ",   "def ",     "func ",      "function ", "function(", "fn ",       "pub fn ",
        "class ",  "struct ",  "interface ", "enum ",     "const ",    "let ",      "var ",
        "val ",    "return ",  "return;",    "yield ",    "throw ",    "import ",   "export ",
        "using ",  "package ", "try {",      "catch ",    "catch(",    "finally {", "except ",
        "except:", "console.", "fmt.",       "print(",    "println(",
    };

    for (code_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }

    if (std.mem.endsWith(u8, trimmed, ";")) {
        if (std.mem.indexOfAny(u8, trimmed, "()={}") != null or
            std.mem.indexOf(u8, trimmed, ":=") != null)
        {
            return true;
        }
    }

    if (std.mem.endsWith(u8, trimmed, "{") or
        std.mem.eql(u8, trimmed, "}") or
        std.mem.eql(u8, trimmed, "};"))
    {
        return true;
    }

    if (std.mem.indexOf(u8, trimmed, " := ") != null) return true;

    return false;
}

fn gatherComments(node: bindings.TSNode, list: *std.ArrayList(bindings.TSNode), allocator: std.mem.Allocator) !void {
    if (node.isNull()) return;
    if (std.mem.eql(u8, node.getType(), "comment")) {
        try list.append(allocator, node);
        return;
    }
    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try gatherComments(node.child(i), list, allocator);
    }
}

fn collectCommentedCode(
    allocator: std.mem.Allocator,
    root: bindings.TSNode,
    source: []const u8,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    var comments: std.ArrayList(bindings.TSNode) = .empty;
    defer comments.deinit(allocator);

    try gatherComments(root, &comments, allocator);

    var i: usize = 0;
    while (i < comments.items.len) {
        const j = findCommentBlockEnd(comments.items, i);

        const code_point = findFirstCodePoint(comments.items, i, j, source);
        if (code_point) |pt| {
            try findings.append(allocator, .{
                .rule = .commented_code,
                .line = pt.row + 1,
                .column = pt.column + 1,
                .message = "commented-out code block detected",
                .snippet = grammars.getLineSnippet(source, pt.row),
            });
        }

        i = j;
    }
}

fn extractStringLiteralContent(raw: []const u8) ?[]const u8 {
    if (raw.len < 2) return null;

    // Go raw string: `content`
    if (raw[0] == '`' and raw[raw.len - 1] == '`') {
        return raw[1 .. raw.len - 1];
    }

    if (extractTripleQuoted(raw)) |inner| return inner;

    // Python raw string: r"content" or r'content'
    if (raw.len >= 3 and (raw[0] == 'r' or raw[0] == 'R')) {
        if ((raw[1] == '"' and raw[raw.len - 1] == '"') or
            (raw[1] == '\'' and raw[raw.len - 1] == '\''))
        {
            return raw[2 .. raw.len - 1];
        }
    }

    // C# verbatim string: @"content"
    if (raw.len >= 3 and raw[0] == '@' and raw[1] == '"' and raw[raw.len - 1] == '"') {
        return raw[2 .. raw.len - 1];
    }

    // Rust raw string: r"content", r#"content"#, r##"content"##
    if (extractRustRawString(raw)) |inner| return inner;

    // Standard string: "content" or 'content'
    if ((raw[0] == '"' and raw[raw.len - 1] == '"') or
        (raw[0] == '\'' and raw[raw.len - 1] == '\''))
    {
        return raw[1 .. raw.len - 1];
    }

    return null;
}

fn scanLiterals(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    source: []const u8,
    map: *std.StringHashMap(LiteralOccur),
) !void {
    if (node.isNull()) return;

    const t = node.getType();
    if (isStringLiteralNode(t) and !isIgnoredLiteralContext(node)) {
        try scanLiteralNode(allocator, node, source, map);
    }

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try scanLiterals(allocator, node.child(i), source, map);
    }
}

fn isIgnoredLiteralContext(node: bindings.TSNode) bool {
    var curr = node.parent();
    while (!curr.isNull()) {
        const t = curr.getType();
        if (isImportOrAttributeType(t)) return true;
        if (std.mem.eql(u8, t, "statement_block") or
            std.mem.eql(u8, t, "block") or
            std.mem.eql(u8, t, "class_body") or
            std.mem.eql(u8, t, "declaration_list") or
            std.mem.eql(u8, t, "function_declaration") or
            std.mem.eql(u8, t, "method_definition"))
        {
            return false;
        }
        curr = curr.parent();
    }
    return false;
}

fn isImportOrAttributeType(t: []const u8) bool {
    if (std.mem.eql(u8, t, "import_statement") or
        std.mem.eql(u8, t, "import_from_statement") or
        std.mem.eql(u8, t, "import_declaration") or
        std.mem.eql(u8, t, "import_specifier") or
        std.mem.eql(u8, t, "use_declaration") or
        std.mem.eql(u8, t, "using_directive") or
        std.mem.eql(u8, t, "package_clause") or
        std.mem.eql(u8, t, "package_declaration"))
    {
        return true;
    }

    if (std.mem.eql(u8, t, "decorator") or
        std.mem.eql(u8, t, "attribute") or
        std.mem.eql(u8, t, "attribute_item") or
        std.mem.eql(u8, t, "inner_attribute_item") or
        std.mem.eql(u8, t, "attribute_list") or
        std.mem.eql(u8, t, "attribute_argument") or
        std.mem.eql(u8, t, "meta_item") or
        std.mem.eql(u8, t, "meta_name_value") or
        std.mem.eql(u8, t, "annotation"))
    {
        return true;
    }

    return false;
}

fn isStringLiteralNode(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "string_literal") or
        std.mem.eql(u8, node_type, "string") or
        std.mem.eql(u8, node_type, "interpreted_string_literal") or
        std.mem.eql(u8, node_type, "raw_string_literal") or
        std.mem.eql(u8, node_type, "verbatim_string_literal");
}

test "auditNoise - Go nesting > 2" {
    const source =
        \\package main
        \\
        \\func DeeplyNested(x int) {
        \\    if x > 0 {
        \\        if x > 1 {
        \\            if x > 2 {
        \\                println("too deep")
        \\            }
        \\        }
        \\    }
        \\}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .go);
    defer std.testing.allocator.free(findings);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(NoiseRule.excessive_nesting, findings[0].rule);
    try std.testing.expectEqual(@as(u32, 6), findings[0].line);
}

test "auditNoise - TypeScript inline closure > 80 chars" {
    const source =
        \\const handler = () => {
        \\    items.map((arg: string) => { return arg + "abcdefghijklmnopqrstuvwxyz_0123456789_abcdefghijklmnopqrstuvwxyz"; });
        \\};
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer deinitFindings(std.testing.allocator, findings);

    try std.testing.expect(findings.len >= 1);
    var found_long_closure = false;
    for (findings) |f| {
        if (f.rule == .long_closure) found_long_closure = true;
    }
    try std.testing.expect(found_long_closure);
}

test "auditNoise - TypeScript redundant ternary" {
    const source =
        \\function isPositive(n: number): boolean {
        \\    return n > 0 ? true : false;
        \\}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer std.testing.allocator.free(findings);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(NoiseRule.redundant_ternary, findings[0].rule);
    try std.testing.expectEqual(@as(u32, 2), findings[0].line);
}

test "auditNoise - Python repeated literals" {
    const source =
        \\def process():
        \\    k1 = "duplicate_token"
        \\    k2 = "duplicate_token"
        \\    k3 = "duplicate_token"
        \\    return k1 + k2 + k3
    ;

    const findings = try auditNoise(std.testing.allocator, source, .python);
    defer {
        for (findings) |f| {
            if (f.rule == .repeated_literal) { std.testing.allocator.free(f.message); std.testing.allocator.free(f.snippet); }
        }
        std.testing.allocator.free(findings);
    }

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(NoiseRule.repeated_literal, findings[0].rule);
    try std.testing.expectEqualStrings("duplicate_token", findings[0].snippet);
}

test "auditNoise - dirty typescript fixture" {
    const file_handle = std.c.fopen("tests/fixtures/dirty/noisy_typescript.ts", "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file_handle);
    var buf: [4096]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len, file_handle);
    const source = buf[0..n];

    const findings = try auditNoise(std.testing.allocator, source, .typescript);

    defer {
        for (findings) |f| {
            if (f.rule == .repeated_literal) { std.testing.allocator.free(f.message); std.testing.allocator.free(f.snippet); }
        }
        std.testing.allocator.free(findings);
    }

    try std.testing.expect(findings.len > 0);
}

test "auditNoise - redundant ternary false positives with identifiers" {
    const source =
        \\function check(isTrue: boolean, false_positive: boolean): boolean {
        \\    const a = isTrue ? false_positive : false;
        \\    const b = false_positive ? isTrue : true;
        \\    return a ? has_false : is_true;
        \\}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer std.testing.allocator.free(findings);

    var ternary_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .redundant_ternary) ternary_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), ternary_count);
}

test "auditNoise - Python redundant conditional expression" {
    const source =
        \\def check(cond):
        \\    a = True if cond else False
        \\    b = False if cond else True
        \\    c = True if cond else fallback
        \\    return a and b
    ;

    const findings = try auditNoise(std.testing.allocator, source, .python);
    defer std.testing.allocator.free(findings);

    var ternary_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .redundant_ternary) ternary_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ternary_count);
}

test "auditNoise - Rust redundant if expression" {
    const source =
        \\fn check(cond: bool) -> bool {
        \\    let a = if cond { true } else { false };
        \\    let b = if cond { false } else { true };
        \\    let c = if cond { true } else { fallback };
        \\    a && b
        \\}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .rust);
    defer std.testing.allocator.free(findings);

    var ternary_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .redundant_ternary) ternary_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ternary_count);
}

test "auditNoise - ternary with same booleans is not redundant" {
    const source =
        \\function check(cond: boolean): boolean {
        \\    const a = cond ? true : true;
        \\    const b = cond ? false : false;
        \\    return a || b;
        \\}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer std.testing.allocator.free(findings);

    var ternary_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .redundant_ternary) ternary_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), ternary_count);
}

test "auditNoise - string literals in imports and decorators are ignored" {
    const source =
        \\import { a } from "shared-module";
        \\import { b } from "shared-module";
        \\import { c } from "shared-module";
        \\
        \\@Decorator("repeated-meta")
        \\@Decorator("repeated-meta")
        \\@Decorator("repeated-meta")
        \\class Example {}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer {
        for (findings) |f| {
            if (f.rule == .repeated_literal) { std.testing.allocator.free(f.message); std.testing.allocator.free(f.snippet); }
        }
        std.testing.allocator.free(findings);
    }

    var literal_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .repeated_literal) literal_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), literal_count);
}

test "auditNoise - Python and Rust same booleans are not redundant" {
    const py_source =
        \\def check(cond):
        \\    a = True if cond else True
        \\    b = False if cond else False
        \\    return a or b
    ;
    const py_findings = try auditNoise(std.testing.allocator, py_source, .python);
    defer std.testing.allocator.free(py_findings);

    var py_ternary_count: usize = 0;
    for (py_findings) |f| {
        if (f.rule == .redundant_ternary) py_ternary_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), py_ternary_count);

    const rs_source =
        \\fn check(cond: bool) -> bool {
        \\    let a = if cond { true } else { true };
        \\    let b = if cond { false } else { false };
        \\    a || b
        \\}
    ;
    const rs_findings = try auditNoise(std.testing.allocator, rs_source, .rust);
    defer std.testing.allocator.free(rs_findings);

    var rs_ternary_count: usize = 0;
    for (rs_findings) |f| {
        if (f.rule == .redundant_ternary) rs_ternary_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), rs_ternary_count);
}

test "auditNoise - Go imports and C# attributes are ignored for repeated literals" {
    const go_source =
        \\package main
        \\import "github.com/org/common"
        \\import "github.com/org/common"
        \\import "github.com/org/common"
    ;
    const go_findings = try auditNoise(std.testing.allocator, go_source, .go);
    defer {
        for (go_findings) |f| {
            if (f.rule == .repeated_literal) { std.testing.allocator.free(f.message); std.testing.allocator.free(f.snippet); }
        }
        std.testing.allocator.free(go_findings);
    }
    var go_lit_count: usize = 0;
    for (go_findings) |f| {
        if (f.rule == .repeated_literal) go_lit_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), go_lit_count);

    const cs_source =
        \\using System;
        \\[Route("api/endpoint")]
        \\[Route("api/endpoint")]
        \\[Route("api/endpoint")]
        \\public class Service {}
    ;
    const cs_findings = try auditNoise(std.testing.allocator, cs_source, .c_sharp);
    defer {
        for (cs_findings) |f| {
            if (f.rule == .repeated_literal) { std.testing.allocator.free(f.message); std.testing.allocator.free(f.snippet); }
        }
        std.testing.allocator.free(cs_findings);
    }
    var cs_lit_count: usize = 0;
    for (cs_findings) |f| {
        if (f.rule == .repeated_literal) cs_lit_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), cs_lit_count);
}

test "auditNoise - arrow function assigned to variable not flagged as long closure" {
    const source =
        \\const helper = (arg: string) => { return arg + "abcdefghijklmnopqrstuvwxyz_0123456789_abcdefghijklmnopqrstuvwxyz"; };
    ;
    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer deinitFindings(std.testing.allocator, findings);

    for (findings) |f| {
        try std.testing.expect(f.rule != .long_closure);
    }
}

test "auditNoise - arrow function assigned to variable resets nesting depth" {
    const source =
        \\if (outer1) {
        \\    if (outer2) {
        \\        const handler = () => {
        \\            if (a) {
        \\                if (b) {
        \\                    console.log("nesting level 2 inside handler, not excessive");
        \\                }
        \\            }
        \\        };
        \\    }
        \\}
    ;
    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer deinitFindings(std.testing.allocator, findings);

    var excessive_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .excessive_nesting) excessive_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), excessive_count);
}

test "auditNoise - raw compound boolean condition detection" {
    const ts_source =
        \\function check(user: any, config: any) {
        \\    if (user.isActive && config.allowAccess || user.isSuperAdmin) {
        \\        return true;
        \\    }
        \\    while (a && b && c) {
        \\        loop();
        \\    }
        \\}
    ;
    const ts_findings = try auditNoise(std.testing.allocator, ts_source, .typescript);
    defer deinitFindings(std.testing.allocator, ts_findings);

    var raw_bool_count: usize = 0;
    for (ts_findings) |f| {
        if (f.rule == .raw_boolean) raw_bool_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), raw_bool_count);

    const clean_source =
        \\function clean(user: any, config: any) {
        \\    if (user.isActive && config.allowAccess) {
        \\        return true;
        \\    }
        \\    if (hasAccess(user, config)) {
        \\        return true;
        \\    }
        \\}
    ;
    const clean_findings = try auditNoise(std.testing.allocator, clean_source, .typescript);
    defer deinitFindings(std.testing.allocator, clean_findings);

    var clean_raw_count: usize = 0;
    for (clean_findings) |f| {
        if (f.rule == .raw_boolean) clean_raw_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), clean_raw_count);
}

test "auditNoise - Python raw compound boolean condition in if/elif/while" {
    const py_source =
        \\def evaluate(user, flags):
        \\    if user.is_active and flags.has_perm or user.is_admin:
        \\        return True
        \\    elif a or b or c:
        \\        return False
    ;
    const py_findings = try auditNoise(std.testing.allocator, py_source, .python);
    defer deinitFindings(std.testing.allocator, py_findings);

    var py_raw_bool_count: usize = 0;
    for (py_findings) |f| {
        if (f.rule == .raw_boolean) py_raw_bool_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), py_raw_bool_count);
}

test "auditNoise - commented-out code blocks detection" {
    const source =
        \\// Regular explanation comment
        \\// This should not be flagged.
        \\
        \\// const oldVal = calculate(x);
        \\// return oldVal;
        \\
        \\/*
        \\if (debug) {
        \\    console.log("old debug");
        \\}
        \\*/
        \\function active() {
        \\    return 1;
        \\}
    ;
    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer deinitFindings(std.testing.allocator, findings);

    var commented_code_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .commented_code) commented_code_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), commented_code_count);
}

test "auditNoise - regular comments are not flagged as commented code" {
    const source =
        \\// This function computes the result.
        \\// It accepts two arguments: x and y.
        \\// NOTE: Do not change the calculation order.
        \\function compute(x: number, y: number): number {
        \\    return x + y;
        \\}
    ;
    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer deinitFindings(std.testing.allocator, findings);

    var commented_code_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .commented_code) commented_code_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), commented_code_count);
}

test "auditNoise - multiline and raw string literals repeated in Go, Python, Rust, C#" {
    // Go raw backtick string
    {
        const go_source =
            \\package main
            \\func f() {
            \\    a := `duplicate_token`
            \\    b := `duplicate_token`
            \\    c := `duplicate_token`
            \\    _ = a + b + c
            \\}
        ;
        const findings = try auditNoise(std.testing.allocator, go_source, .go);
        defer deinitFindings(std.testing.allocator, findings);

        var found_lit = false;
        for (findings) |f| {
            if (f.rule == .repeated_literal and std.mem.eql(u8, f.snippet, "duplicate_token")) {
                found_lit = true;
            }
        }
        try std.testing.expect(found_lit);
    }

    // Python triple quote string
    {
        const py_source =
            \\def f():
            \\    a = """duplicate_token"""
            \\    b = """duplicate_token"""
            \\    c = """duplicate_token"""
            \\    return a + b + c
        ;
        const findings = try auditNoise(std.testing.allocator, py_source, .python);
        defer deinitFindings(std.testing.allocator, findings);

        var found_lit = false;
        for (findings) |f| {
            if (f.rule == .repeated_literal and std.mem.eql(u8, f.snippet, "duplicate_token")) {
                found_lit = true;
            }
        }
        try std.testing.expect(found_lit);
    }

    // Rust raw string
    {
        const rs_source =
            \\fn f() {
            \\    let a = r#"duplicate_token"#;
            \\    let b = r#"duplicate_token"#;
            \\    let c = r#"duplicate_token"#;
            \\}
        ;
        const findings = try auditNoise(std.testing.allocator, rs_source, .rust);
        defer deinitFindings(std.testing.allocator, findings);

        var found_lit = false;
        for (findings) |f| {
            if (f.rule == .repeated_literal and std.mem.eql(u8, f.snippet, "duplicate_token")) {
                found_lit = true;
            }
        }
        try std.testing.expect(found_lit);
    }

    // C# verbatim string
    {
        const cs_source =
            \\class C {
            \\    void M() {
            \\        var a = @"duplicate_token";
            \\        var b = @"duplicate_token";
            \\        var c = @"duplicate_token";
            \\    }
            \\}
        ;
        const findings = try auditNoise(std.testing.allocator, cs_source, .c_sharp);
        defer deinitFindings(std.testing.allocator, findings);
        var found_lit = false;
        for (findings) |f| {
            if (f.rule == .repeated_literal and std.mem.eql(u8, f.snippet, "duplicate_token")) {
                found_lit = true;
            }
        }
        try std.testing.expect(found_lit);
    }
}

test "deinitFindings handles empty slices, repeated literals, and mixed findings without leaking" {
    deinitFindings(std.testing.allocator, &.{});

    var findings = try std.testing.allocator.alloc(NoiseFinding, 3);
    findings[0] = .{
        .rule = .excessive_nesting,
        .line = 1,
        .column = 1,
        .message = "static message",
        .snippet = "snippet",
    };
    findings[1] = .{
        .rule = .repeated_literal,
        .line = 2,
        .column = 1,
        .message = try std.fmt.allocPrint(std.testing.allocator, "allocated msg {d}", .{42}),
        .snippet = try std.testing.allocator.dupe(u8, "snippet"),
    };
    findings[2] = .{
        .rule = .commented_code,
        .line = 3,
        .column = 1,
        .message = "commented-out code",
        .snippet = "snippet",
    };

    deinitFindings(std.testing.allocator, findings);
}

test "auditNoise - closures reset nesting depth internally" {
    const source =
        \\function outer(a: boolean, b: boolean) {
        \\    if (a) {
        \\        if (b) {
        \\            const cb = () => {
        \\                if (true) {
        \\                    return 1;
        \\                }
        \\            };
        \\        }
        \\    }
        \\}
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer deinitFindings(std.testing.allocator, findings);

    // The if (true) inside the cb closure has nesting 1 relative to closure, so it should NOT be flagged as excessive_nesting
    var excessive_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .excessive_nesting) excessive_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), excessive_count);
}

fn checkExcessiveNesting(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    next_depth: u32,
    config: NoiseConfig,
    source: []const u8,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    if (next_depth <= config.max_nesting) return;
    const pt = node.startPoint();
    try findings.append(allocator, .{
        .rule = .excessive_nesting,
        .line = pt.row + 1,
        .column = pt.column + 1,
        .message = "nesting > 2 levels (guard clause / early return opportunity)",
        .snippet = grammars.getLineSnippet(source, pt.row),
    });
}

fn checkLongClosure(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    lang: grammars.Language,
    config: NoiseConfig,
    source: []const u8,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    if (!lang.isClosure(node.getType())) return;
    const inside = isInsideCallArguments(node);
    const start = node.startByte();
    const end = node.endByte();
    if (!(inside and end > start and (end - start) > config.max_closure_len)) return;
    const pt = node.startPoint();
    try findings.append(allocator, .{
        .rule = .long_closure,
        .line = pt.row + 1,
        .column = pt.column + 1,
        .message = "inline closure exceeds 80 characters",
        .snippet = grammars.getLineSnippet(source, pt.row),
    });
}

fn checkRedundantTernaryFinding(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    lang: grammars.Language,
    source: []const u8,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    if (!lang.isTernary(node.getType())) return;
    if (!isRedundantTernary(node, source, lang)) return;
    const pt = node.startPoint();
    try findings.append(allocator, .{
        .rule = .redundant_ternary,
        .line = pt.row + 1,
        .column = pt.column + 1,
        .message = "redundant ternary boolean expression",
        .snippet = grammars.getLineSnippet(source, pt.row),
    });
}

fn checkRawBoolean(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    lang: grammars.Language,
    source: []const u8,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    if (!lang.isIfOrWhile(node.getType())) return;
    const cond = node.childByFieldName("condition");
    if (cond.isNull()) return;
    if (countLogicalOperators(cond, source, lang) < 2) return;
    const pt = node.startPoint();
    try findings.append(allocator, .{
        .rule = .raw_boolean,
        .line = pt.row + 1,
        .column = pt.column + 1,
        .message = "raw compound boolean condition (extract to domain predicate)",
        .snippet = grammars.getLineSnippet(source, pt.row),
    });
}

fn extractRustRawString(raw: []const u8) ?[]const u8 {
    if (raw.len < 3 or raw[0] != 'r') return null;
    var hashes: usize = 0;
    while (1 + hashes < raw.len and raw[1 + hashes] == '#') : (hashes += 1) {}
    if (!(1 + hashes < raw.len and raw[1 + hashes] == '"')) return null;
    const prefix_len = hashes + 2;
    const suffix_len = hashes + 1;
    if (raw.len < prefix_len + suffix_len) return null;
    if (raw[raw.len - 1 - hashes] != '"') return null;
    var h: usize = 0;
    while (h < hashes) : (h += 1) {
        if (raw[raw.len - 1 - h] != '#') return null;
    }
    return raw[prefix_len .. raw.len - suffix_len];
}

fn extractTripleQuoted(raw: []const u8) ?[]const u8 {
    if (raw.len >= 6 and std.mem.startsWith(u8, raw, "\"\"\"") and std.mem.endsWith(u8, raw, "\"\"\"")) {
        return raw[3 .. raw.len - 3];
    }
    if (raw.len >= 6 and std.mem.startsWith(u8, raw, "'''") and std.mem.endsWith(u8, raw, "'''")) {
        return raw[3 .. raw.len - 3];
    }
    if (raw.len >= 7 and (raw[0] == 'r' or raw[0] == 'R') and
        std.mem.startsWith(u8, raw[1..], "\"\"\"") and std.mem.endsWith(u8, raw, "\"\"\""))
    {
        return raw[4 .. raw.len - 3];
    }
    if (raw.len >= 7 and (raw[0] == 'r' or raw[0] == 'R') and
        std.mem.startsWith(u8, raw[1..], "'''") and std.mem.endsWith(u8, raw, "'''"))
    {
        return raw[4 .. raw.len - 3];
    }
    return null;
}

fn findCommentBlockEnd(comments: []bindings.TSNode, start: usize) usize {
    var last = comments[start];
    var j = start + 1;
    while (j < comments.len) : (j += 1) {
        const next = comments[j];
        if (next.startPoint().row <= last.endPoint().row + 1) {
            last = next;
        } else {
            break;
        }
    }
    return j;
}

fn findFirstCodePoint(comments: []bindings.TSNode, start: usize, end: usize, source: []const u8) ?bindings.TSPoint {
    var k = start;
    while (k < end) : (k += 1) {
        const c_node = comments[k];
        const text = c_node.slice(source);
        var line_it = std.mem.splitScalar(u8, text, '\n');
        var line_offset: u32 = 0;
        while (line_it.next()) |line| : (line_offset += 1) {
            const cleaned = cleanCommentLine(line);
            if (isCodeLine(cleaned)) {
                return .{
                    .row = c_node.startPoint().row + line_offset,
                    .column = c_node.startPoint().column,
                };
            }
        }
    }
    return null;
}

fn scanLiteralNode(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    source: []const u8,
    map: *std.StringHashMap(LiteralOccur),
) !void {
    const raw = node.slice(source);
    const inner = extractStringLiteralContent(raw) orelse return;
    if (inner.len < 4) return;
    const pt = node.startPoint();
    const owned = try allocator.dupe(u8, inner);
    errdefer allocator.free(owned);
    if (map.getEntry(owned)) |entry| {
        allocator.free(owned);
        entry.value_ptr.count += 1;
    } else {
        try map.put(owned, .{
            .count = 1,
            .line = pt.row + 1,
            .col = pt.column + 1,
        });
    }
}
