const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const FunctionRecord = struct {
    name: []const u8,
    line: u32,
    end_line: u32,
    complexity: u32,
};

pub fn calculateComplexity(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) ![]FunctionRecord {
    const ts_lang = lang.getTsLanguage() orelse return &.{};

    var parser = try bindings.Parser.init();
    defer parser.deinit();

    if (!parser.setLanguage(ts_lang)) return error.SetLanguageFailed;

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const root = tree.rootNode();
    var records: std.ArrayList(FunctionRecord) = .empty;
    defer records.deinit(allocator);

    try collectFunctions(allocator, root, source, lang, &records);

    return records.toOwnedSlice(allocator);
}

fn collectFunctions(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    source: []const u8,
    lang: grammars.Language,
    records: *std.ArrayList(FunctionRecord),
) !void {
    if (node.isNull()) return;

    if (isFunctionNode(node, lang)) {
        const name = getFunctionName(node, source, lang);
        const start = node.startPoint();
        const end = node.endPoint();

        var score: u32 = 0;
        walkNode(node, source, lang, 0, &score);

        try records.append(allocator, .{
            .name = name,
            .line = start.row + 1,
            .end_line = end.row + 1,
            .complexity = score,
        });

        // Continue into children to find any inner/nested functions
        var i: u32 = 0;
        const count = node.childCount();
        while (i < count) : (i += 1) {
            try collectFunctions(allocator, node.child(i), source, lang, records);
        }
        return;
    }

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        try collectFunctions(allocator, node.child(i), source, lang, records);
    }
}

fn isFunctionNode(node: bindings.TSNode, lang: grammars.Language) bool {
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

fn getFunctionName(node: bindings.TSNode, source: []const u8, lang: grammars.Language) []const u8 {
    _ = lang;
    const name_node = node.childByFieldName("name");
    if (!name_node.isNull()) {
        const name_slice = name_node.slice(source);
        if (name_slice.len > 0) return name_slice;
    }
    return "anonymous";
}

fn walkNode(
    node: bindings.TSNode,
    source: []const u8,
    lang: grammars.Language,
    nesting: u32,
    score: *u32,
) void {
    if (node.isNull()) return;

    const t = node.getType();

    // Explicitly ignore optional chaining and nullable types
    if (isIgnoredNode(t)) return;

    var next_nesting = nesting;

    if (isIfNode(t, lang)) {
        if (isElseIf(node, lang)) {
            score.* += 1;
        } else {
            score.* += 1 + nesting;
        }
        next_nesting = nesting + 1;
    } else if (isElseNode(node, source, lang)) {
        score.* += 1;
        next_nesting = nesting + 1;
    } else if (isTernaryNode(t, lang)) {
        score.* += 1 + nesting;
        next_nesting = nesting + 1;
    } else if (isSwitchNode(t, lang)) {
        score.* += 1 + nesting;
        next_nesting = nesting + 1;
    } else if (isLoopNode(t, lang)) {
        score.* += 1 + nesting;
        next_nesting = nesting + 1;
    } else if (isCatchNode(t, lang)) {
        score.* += 1 + nesting;
        next_nesting = nesting + 1;
    } else if (isClosureNode(t, lang)) {
        next_nesting = nesting + 1;
    } else if (getLogicalOperator(node, source, lang)) |op| {
        if (!parentHasSameLogicalOperator(node, op, source, lang)) {
            score.* += 1;
        }
    }

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        walkNode(node.child(i), source, lang, next_nesting, score);
    }
}

fn isIgnoredNode(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "nullable_type") or
        std.mem.eql(u8, node_type, "conditional_access_expression") or
        std.mem.eql(u8, node_type, "optional_chain");
}

fn isIfNode(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "if_statement"),
        .rust => std.mem.eql(u8, node_type, "if_expression"),
        .python => std.mem.eql(u8, node_type, "if_statement") or std.mem.eql(u8, node_type, "elif_clause"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "if_statement"),
        .c_sharp => std.mem.eql(u8, node_type, "if_statement"),
        .unknown => false,
    };
}

fn isElseIf(node: bindings.TSNode, lang: grammars.Language) bool {
    const t = node.getType();
    if (lang == .python and std.mem.eql(u8, t, "elif_clause")) {
        return true;
    }

    const p = node.parent();
    if (p.isNull()) return false;
    const pt = p.getType();

    if (lang == .go) {
        if (std.mem.eql(u8, pt, "if_statement")) {
            const alt = p.childByFieldName("alternative");
            if (!alt.isNull() and alt.startByte() == node.startByte()) return true;
        }
    } else if (lang == .rust) {
        if (std.mem.eql(u8, pt, "else_clause") or std.mem.eql(u8, pt, "if_expression")) {
            return true;
        }
    } else {
        if (std.mem.eql(u8, pt, "else_clause")) {
            return true;
        }
    }
    return false;
}

fn isElseNode(node: bindings.TSNode, source: []const u8, lang: grammars.Language) bool {
    _ = source;
    const t = node.getType();
    if (lang == .python) {
        return std.mem.eql(u8, t, "else_clause");
    }

    if (lang == .go) {
        const p = node.parent();
        if (!p.isNull() and std.mem.eql(u8, p.getType(), "if_statement")) {
            const alt = p.childByFieldName("alternative");
            if (!alt.isNull() and alt.startByte() == node.startByte()) {
                // If alternative is a block, this is the else branch
                return std.mem.eql(u8, t, "block");
            }
        }
        return false;
    }

    if (std.mem.eql(u8, t, "else_clause")) {
        // If it contains an if_statement child, it's else-if and the if_statement will handle it
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

fn isTernaryNode(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .typescript, .tsx => std.mem.eql(u8, node_type, "ternary_expression"),
        .c_sharp, .python => std.mem.eql(u8, node_type, "conditional_expression"),
        else => false,
    };
}

fn isSwitchNode(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "expression_switch_statement") or
            std.mem.eql(u8, node_type, "type_switch_statement") or
            std.mem.eql(u8, node_type, "select_statement"),
        .rust => std.mem.eql(u8, node_type, "match_expression"),
        .python => std.mem.eql(u8, node_type, "match_statement"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "switch_statement"),
        .c_sharp => std.mem.eql(u8, node_type, "switch_statement") or
            std.mem.eql(u8, node_type, "switch_expression"),
        .unknown => false,
    };
}

fn isLoopNode(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .go => std.mem.eql(u8, node_type, "for_statement"),
        .rust => std.mem.eql(u8, node_type, "for_expression") or
            std.mem.eql(u8, node_type, "while_expression") or
            std.mem.eql(u8, node_type, "loop_expression"),
        .python => std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "while_statement"),
        .typescript, .tsx => std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "for_in_statement") or
            std.mem.eql(u8, node_type, "for_of_statement") or
            std.mem.eql(u8, node_type, "while_statement") or
            std.mem.eql(u8, node_type, "do_statement"),
        .c_sharp => std.mem.eql(u8, node_type, "for_statement") or
            std.mem.eql(u8, node_type, "for_each_statement") or
            std.mem.eql(u8, node_type, "while_statement") or
            std.mem.eql(u8, node_type, "do_statement"),
        .unknown => false,
    };
}

fn isCatchNode(node_type: []const u8, lang: grammars.Language) bool {
    return switch (lang) {
        .python => std.mem.eql(u8, node_type, "except_clause") or
            std.mem.eql(u8, node_type, "except_group_clause"),
        .typescript, .tsx, .c_sharp => std.mem.eql(u8, node_type, "catch_clause"),
        else => false,
    };
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

fn getLogicalOperator(node: bindings.TSNode, source: []const u8, lang: grammars.Language) ?[]const u8 {
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

fn parentHasSameLogicalOperator(
    node: bindings.TSNode,
    op: []const u8,
    source: []const u8,
    lang: grammars.Language,
) bool {
    var curr = node.parent();
    while (!curr.isNull()) {
        const ptype = curr.getType();
        if (std.mem.eql(u8, ptype, "parenthesized_expression") or
            std.mem.eql(u8, ptype, "(") or
            std.mem.eql(u8, ptype, ")"))
        {
            curr = curr.parent();
            continue;
        }

        if (getLogicalOperator(curr, source, lang)) |parent_op| {
            return std.mem.eql(u8, parent_op, op);
        }
        break;
    }
    return false;
}

test "calculateComplexity - Go sample" {
    const source =
        \\package main
        \\
        \\func Process(x int, y int) int {
        \\    if x > 0 && y > 0 {
        \\        for i := 0; i < x; i++ {
        \\            if i > 5 {
        \\                return i
        \\            }
        \\        }
        \\    } else if x < 0 {
        \\        return -1
        \\    } else {
        \\        return 0
        \\    }
        \\    return 1
        \\}
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .go);
    defer std.testing.allocator.free(funcs);

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("Process", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 3), funcs[0].line);
    try std.testing.expectEqual(@as(u32, 16), funcs[0].end_line);
    try std.testing.expectEqual(@as(u32, 9), funcs[0].complexity);
}

test "calculateComplexity - Python sample" {
    const source =
        \\def compute_score(val, flag):
        \\    try:
        \\        if val > 10 and flag:
        \\            while val > 0:
        \\                val -= 1
        \\        elif val < 0 or not flag:
        \\            return -1
        \\        else:
        \\            return 0
        \\    except Exception:
        \\        return -99
        \\    return val
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .python);
    defer std.testing.allocator.free(funcs);

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("compute_score", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].line);
    try std.testing.expectEqual(@as(u32, 8), funcs[0].complexity);
}

test "calculateComplexity - TypeScript sample with optional chaining" {
    const source =
        \\function handleData(user: any, options?: any): number {
        \\    const config = options?.settings?.threshold;
        \\    if (user.isActive && user.hasPermission) {
        \\        const limit = user.isAdmin ? 100 : 50;
        \\        switch (user.role) {
        \\            case "admin":
        \\                return limit * 2;
        \\            default:
        \\                return limit;
        \\        }
        \\    }
        \\    try {
        \\        return 0;
        \\    } catch (e) {
        \\        return -1;
        \\    }
        \\}
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .typescript);
    defer std.testing.allocator.free(funcs);

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("handleData", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].line);
    try std.testing.expectEqual(@as(u32, 7), funcs[0].complexity);
}

test "calculateComplexity - C# sample with nullable types and null conditional" {
    const source =
        \\public class Service {
        \\    public int? Process(int? input, string data) {
        \\        int? result = input?.Value;
        \\        if (result > 0) {
        \\            return result > 10 ? 1 : 2;
        \\        }
        \\        return 0;
        \\    }
        \\}
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .c_sharp);
    defer std.testing.allocator.free(funcs);

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("Process", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 3), funcs[0].complexity);
}
