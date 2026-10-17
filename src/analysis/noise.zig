const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const NoiseRule = enum {
    excessive_nesting,
    long_closure,
    redundant_ternary,
    repeated_literal,

    pub fn asString(self: NoiseRule) []const u8 {
        return switch (self) {
            .excessive_nesting => "excessive-nesting",
            .long_closure => "long-closure",
            .redundant_ternary => "redundant-ternary",
            .repeated_literal => "repeated-literal",
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

pub fn auditNoise(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
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

    // 1. AST walk for structural nesting, closures, and redundant ternaries
    try walkNoise(allocator, root, source, lang, 0, &findings);

    // 2. Scan repeated string literals
    try collectRepeatedLiterals(allocator, root, source, &findings);

    return findings.toOwnedSlice(allocator);
}

pub fn deinitFindings(allocator: std.mem.Allocator, findings: []NoiseFinding) void {
    for (findings) |f| {
        if (f.rule == .repeated_literal) allocator.free(f.message);
    }
    allocator.free(findings);
}

fn walkNoise(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    source: []const u8,
    lang: grammars.Language,
    depth: u32,
    findings: *std.ArrayList(NoiseFinding),
) !void {
    if (node.isNull()) return;

    const t = node.getType();
    var next_depth = depth;

    // Reset nesting depth at function boundaries
    if (isFunctionBoundary(t, lang)) {
        next_depth = 0;
    } else if (isControlNode(t, lang)) {
        const is_elif = isElseIfNode(node, lang);
        if (!is_elif) {
            next_depth = depth + 1;
            if (next_depth > 2) {
                const pt = node.startPoint();
                try findings.append(allocator, .{
                    .rule = .excessive_nesting,
                    .line = pt.row + 1,
                    .column = pt.column + 1,
                    .message = "nesting > 2 levels (guard clause / early return opportunity)",
                    .snippet = getLineSnippet(source, pt.row),
                });
            }
        }
    }

    // Check inline closures > 80 characters
    if (isClosureNode(t, lang)) {
        const start = node.startByte();
        const end = node.endByte();
        if (end > start and (end - start) > 80) {
            const pt = node.startPoint();
            try findings.append(allocator, .{
                .rule = .long_closure,
                .line = pt.row + 1,
                .column = pt.column + 1,
                .message = "inline closure exceeds 80 characters",
                .snippet = getLineSnippet(source, pt.row),
            });
        }
    }

    // Check redundant ternaries (e.g., cond ? true : false)
    if (isTernaryNode(t, lang)) {
        if (isRedundantTernary(node, source, lang)) {
            const pt = node.startPoint();
            try findings.append(allocator, .{
                .rule = .redundant_ternary,
                .line = pt.row + 1,
                .column = pt.column + 1,
                .message = "redundant ternary boolean expression",
                .snippet = getLineSnippet(source, pt.row),
            });
        }
    }

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try walkNoise(allocator, node.child(i), source, lang, next_depth, findings);
    }
}

fn isFunctionBoundary(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "function_declaration") or std.mem.eql(u8, node_type, "method_declaration"),
        .rust => std.mem.eql(u8, node_type, "function_item"),
        .python => std.mem.eql(u8, node_type, "function_definition"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "function_declaration") or std.mem.eql(u8, node_type, "method_definition"),
        .c_sharp => std.mem.eql(u8, node_type, "method_declaration") or std.mem.eql(u8, node_type, "local_function_statement"),
        .unknown => false,
    };
}

fn isControlNode(node_type: []const u8, lang: grammars.Language) bool {
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

fn isElseIfNode(node: bindings.TSNode, lang: grammars.Language) bool {
    const t = node.getType();
    if (lang == .python and std.mem.eql(u8, t, "elif_clause")) return true;

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

fn isClosureNode(node_type: []const u8, lang: grammars.Language) bool {
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

fn isTernaryNode(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .typescript, .tsx => std.mem.eql(u8, node_type, "ternary_expression"),
        .c_sharp, .python => std.mem.eql(u8, node_type, "conditional_expression"),
        else => false,
    };
}

fn isRedundantTernary(node: bindings.TSNode, source: []const u8, lang: grammars.Language) bool {
    _ = lang;
    const consequence = node.childByFieldName("consequence");
    const alternative = node.childByFieldName("alternative");

    if (!consequence.isNull() and !alternative.isNull()) {
        const cons_text = std.mem.trim(u8, consequence.slice(source), " \t\r\n;");
        const alt_text = std.mem.trim(u8, alternative.slice(source), " \t\r\n;");

        const is_true_false = (std.mem.eql(u8, cons_text, "true") or std.mem.eql(u8, cons_text, "True")) and
            (std.mem.eql(u8, alt_text, "false") or std.mem.eql(u8, alt_text, "False"));
        const is_false_true = (std.mem.eql(u8, cons_text, "false") or std.mem.eql(u8, cons_text, "False")) and
            (std.mem.eql(u8, alt_text, "true") or std.mem.eql(u8, alt_text, "True"));

        if (is_true_false or is_false_true) return true;
    }

    // Also check raw slice for ternary boolean patterns like `? true : false`
    const raw = node.slice(source);
    if (std.mem.indexOf(u8, raw, "?") != null and std.mem.indexOf(u8, raw, ":") != null) {
        if (std.mem.indexOf(u8, raw, "true") != null and std.mem.indexOf(u8, raw, "false") != null) {
            return true;
        }
        if (std.mem.indexOf(u8, raw, "True") != null and std.mem.indexOf(u8, raw, "False") != null) {
            return true;
        }
    }

    return false;
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
    defer literal_map.deinit();

    try scanLiterals(root, source, &literal_map);

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
                .snippet = entry.key_ptr.*,
            });
        }
    }
}

fn scanLiterals(
    node: bindings.TSNode,
    source: []const u8,
    map: *std.StringHashMap(LiteralOccur),
) !void {
    if (node.isNull()) return;

    const t = node.getType();
    if (isStringLiteralNode(t)) {
        var raw = node.slice(source);
        if (raw.len >= 6) { // e.g. "text" (4 chars inner + 2 quotes)
            if ((raw[0] == '"' and raw[raw.len - 1] == '"') or
                (raw[0] == '\'' and raw[raw.len - 1] == '\''))
            {
                const inner = raw[1 .. raw.len - 1];
                if (inner.len >= 4) {
                    const pt = node.startPoint();
                    if (map.getEntry(inner)) |entry| {
                        entry.value_ptr.count += 1;
                    } else {
                        try map.put(inner, .{
                            .count = 1,
                            .line = pt.row + 1,
                            .col = pt.column + 1,
                        });
                    }
                }
            }
        }
    }

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try scanLiterals(node.child(i), source, map);
    }
}

fn isStringLiteralNode(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "string_literal") or
        std.mem.eql(u8, node_type, "string") or
        std.mem.eql(u8, node_type, "interpreted_string_literal") or
        std.mem.eql(u8, node_type, "raw_string_literal");
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
        \\    const helper = (arg: string) => { return arg + "abcdefghijklmnopqrstuvwxyz_0123456789_abcdefghijklmnopqrstuvwxyz"; };
        \\};
    ;

    const findings = try auditNoise(std.testing.allocator, source, .typescript);
    defer std.testing.allocator.free(findings);

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
            if (f.rule == .repeated_literal) std.testing.allocator.free(f.message);
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
            if (f.rule == .repeated_literal) std.testing.allocator.free(f.message);
        }
        std.testing.allocator.free(findings);
    }

    try std.testing.expect(findings.len > 0);
}


