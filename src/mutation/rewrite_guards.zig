const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");
const edits = @import("edits.zig");
const proposal = @import("proposal.zig");

pub const GUARD_RULE = "excessive-nesting";
pub const GUARD_MESSAGE = "invert condition and return early to flatten nesting";

/// Grammar vocabulary the guard pass needs per language. Values are verified by
/// the probe tests in this file against the embedded grammars.
const GuardSyntax = struct {
    if_nodes: []const []const u8,
    condition_field: []const u8,
    body_field: []const u8,
    else_field: []const u8,
    early_return: []const u8,
    invert_prefix: []const u8,
};

/// `consequence` holds a `statement_block`; the condition is a
/// `parenthesized_expression`, so its slice keeps the `if` parentheses.
const typescript_syntax = GuardSyntax{
    .if_nodes = &.{"if_statement"},
    .condition_field = "condition",
    .body_field = "consequence",
    .else_field = "alternative",
    .early_return = "{ return; }",
    .invert_prefix = "!",
};

/// `consequence` holds a `block`; a `statement_list` may sit between the `if`
/// and its parent block, and `initializer` marks the two-statement form.
const go_syntax = GuardSyntax{
    .if_nodes = &.{"if_statement"},
    .condition_field = "condition",
    .body_field = "consequence",
    .else_field = "alternative",
    .early_return = "{ return }",
    .invert_prefix = "!",
};

/// The Zig `if_statement` keeps its block under the `body` field and emits
/// `else_clause` children without a field name.
const zig_syntax = GuardSyntax{
    .if_nodes = &.{"if_statement"},
    .condition_field = "condition",
    .body_field = "body",
    .else_field = "",
    .early_return = "{ return; }",
    .invert_prefix = "!",
};

/// Rust `if` is an expression; only statement positions qualify, and `match`
/// arms, loops, and closures all force an advisory result.
const rust_syntax = GuardSyntax{
    .if_nodes = &.{"if_expression"},
    .condition_field = "condition",
    .body_field = "consequence",
    .else_field = "alternative",
    .early_return = "{ return; }",
    .invert_prefix = "!",
};

/// Python bodies are brace-less `block` nodes indented by tabs or spaces; the
/// guard line uses `not (...)` and carries the `:` itself.
const python_syntax = GuardSyntax{
    .if_nodes = &.{"if_statement"},
    .condition_field = "condition",
    .body_field = "consequence",
    .else_field = "alternative",
    .early_return = "return",
    .invert_prefix = "not ",
};

/// C# `method_declaration` and `local_function_statement` both keep their body
/// in `consequence`-style blocks; return types live under `returns`/`type`.
const c_sharp_syntax = GuardSyntax{
    .if_nodes = &.{"if_statement"},
    .condition_field = "condition",
    .body_field = "consequence",
    .else_field = "alternative",
    .early_return = "{ return; }",
    .invert_prefix = "!",
};

fn syntaxFor(lang: grammars.Language) ?*const GuardSyntax {
    return switch (lang) {
        .typescript, .tsx => &typescript_syntax,
        .go => &go_syntax,
        .zig => &zig_syntax,
        .rust => &rust_syntax,
        .python => &python_syntax,
        .c_sharp => &c_sharp_syntax,
        else => null,
    };
}

pub fn supportedLanguages() []const grammars.Language {
    return &.{ .typescript, .tsx, .go, .zig, .rust, .python, .c_sharp };
}

pub fn collect(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    const syntax = syntaxFor(lang) orelse return &.{};

    var candidates: std.ArrayList(GuardCandidate) = .empty;
    defer candidates.deinit(allocator);
    errdefer for (candidates.items) |candidate| allocator.free(candidate.replacement);

    try collectCandidates(allocator, source, lang, syntax, root, &candidates);
    keepInnermost(allocator, &candidates);

    const out = try allocator.alloc(proposal.Proposal, candidates.items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |p| p.deinit(allocator);
        allocator.free(out);
        for (candidates.items[built..]) |candidate| allocator.free(candidate.replacement);
    }
    for (candidates.items, 0..) |candidate, i| {
        out[i] = try makeProposal(allocator, candidate);
        built += 1;
    }
    return out;
}

const GuardCandidate = struct {
    node: bindings.TSNode,
    replacement: []u8,
};

fn collectCandidates(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    syntax: *const GuardSyntax,
    node: bindings.TSNode,
    out: *std.ArrayList(GuardCandidate),
) !void {
    if (node.isNull()) return;

    if (matchesAny(node.getType(), syntax.if_nodes)) {
        if (try analyzeIf(allocator, source, lang, syntax, node)) |candidate| {
            try out.append(allocator, candidate);
        }
    }

    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        try collectCandidates(allocator, source, lang, syntax, node.namedChild(i), out);
    }
}

/// An `if` qualifies only when it carries no else branch, no construct that
/// changes the meaning of an early return, sits in the tail chain of a
/// void-capable function, has a clean body, and can be de-indented one level.
fn analyzeIf(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    syntax: *const GuardSyntax,
    if_node: bindings.TSNode,
) !?GuardCandidate {
    if (hasElseBranch(syntax, if_node)) return null;
    if (hasUnsupportedConstruct(syntax, if_node)) return null;
    if (!isStatementPosition(lang, if_node)) return null;

    const boundary = enclosingFunction(lang, if_node) orelse return null;
    if (!isVoidCapable(lang, source, boundary)) return null;
    if (!isCleanBody(syntax, source, if_node)) return null;
    if (try buildReplacement(allocator, source, lang, syntax, if_node)) |replacement| {
        return .{ .node = if_node, .replacement = replacement };
    }
    return null;
}

fn makeProposal(allocator: std.mem.Allocator, candidate: GuardCandidate) !proposal.Proposal {
    const edit_slice = try allocator.alloc(edits.Edit, 1);
    errdefer allocator.free(edit_slice);
    edit_slice[0] = .{
        .start = candidate.node.startByte(),
        .end = candidate.node.endByte(),
        .replacement = candidate.replacement,
    };

    const rule = try allocator.dupe(u8, GUARD_RULE);
    errdefer allocator.free(rule);
    const file = try allocator.dupe(u8, "");
    errdefer allocator.free(file);
    const message = try allocator.dupe(u8, GUARD_MESSAGE);
    errdefer allocator.free(message);
    const hash = try allocator.dupe(u8, "");
    errdefer allocator.free(hash);

    const point = candidate.node.startPoint();
    return .{
        .kind = .guard,
        .rule = rule,
        .file = file,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = message,
        .confidence = .medium,
        .naming_required = false,
        .safe_to_apply = true,
        .edits = edit_slice,
        .expected_hash = hash,
    };
}

/// Drops any candidate whose range contains another candidate: when eligible
/// `if`s nest, only the innermost one is proposed; the outer becomes eligible
/// on the next plan cycle, once the inner guard is applied.
fn keepInnermost(allocator: std.mem.Allocator, candidates: *std.ArrayList(GuardCandidate)) void {
    var write: usize = 0;
    for (candidates.items, 0..) |candidate, i| {
        if (hasInnerCandidate(candidates.items, i)) {
            allocator.free(candidate.replacement);
            continue;
        }
        candidates.items[write] = candidate;
        write += 1;
    }
    candidates.shrinkRetainingCapacity(write);
}

fn hasInnerCandidate(candidates: []const GuardCandidate, index: usize) bool {
    const candidate = candidates[index];
    const start = candidate.node.startByte();
    const end = candidate.node.endByte();
    for (candidates, 0..) |other, j| {
        if (j == index) continue;
        const other_start = other.node.startByte();
        const other_end = other.node.endByte();
        const nested = other_start >= start and other_end <= end;
        const same_span = other_start == start and other_end == end;
        if (nested and !same_span) return true;
    }
    return false;
}

fn hasElseBranch(syntax: *const GuardSyntax, if_node: bindings.TSNode) bool {
    if (syntax.else_field.len > 0 and !if_node.childByFieldName(syntax.else_field).isNull()) {
        return true;
    }
    var i: u32 = 0;
    while (i < if_node.namedChildCount()) : (i += 1) {
        const child_type = if_node.namedChild(i).getType();
        if (std.mem.eql(u8, child_type, "else_clause") or std.mem.eql(u8, child_type, "elif_clause")) {
            return true;
        }
    }
    return false;
}

/// Constructs whose initializer or capture the guard rewrite would drop.
fn hasUnsupportedConstruct(syntax: *const GuardSyntax, if_node: bindings.TSNode) bool {
    if (!if_node.childByFieldName("initializer").isNull()) return true;

    const condition = if_node.childByFieldName(syntax.condition_field);
    if (!condition.isNull() and subtreeContainsType(condition, "let_condition")) return true;

    var i: u32 = 0;
    while (i < if_node.namedChildCount()) : (i += 1) {
        if (std.mem.eql(u8, if_node.namedChild(i).getType(), "payload")) return true;
    }
    return false;
}

fn subtreeContainsType(node: bindings.TSNode, node_type: []const u8) bool {
    if (std.mem.eql(u8, node.getType(), node_type)) return true;
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const child = node.namedChild(i);
        if (subtreeContainsType(child, node_type)) return true;
    }
    return false;
}

fn isStatementPosition(lang: grammars.Language, if_node: bindings.TSNode) bool {
    if (lang != .rust) return true;
    const parent = if_node.parent();
    if (parent.isNull()) return false;
    const parent_type = parent.getType();
    return std.mem.eql(u8, parent_type, "expression_statement") or
        std.mem.eql(u8, parent_type, "block");
}

/// Walks up the block chain towards the enclosing function. Every level must
/// leave the current node as the last named sibling (comments count: they are
/// named nodes) and no level may introduce a loop, switch, handler, `finally`,
/// label, or closure. Returns the enclosing function node.
fn enclosingFunction(lang: grammars.Language, if_node: bindings.TSNode) ?bindings.TSNode {
    var child = if_node;
    while (true) {
        const parent = child.parent();
        if (parent.isNull()) return null;

        const parent_type = parent.getType();
        if (isFunctionBoundary(lang, parent)) return parent;
        if (isBlockingContext(lang, parent_type)) return null;
        if (lang.isClosure(parent_type)) return null;
        if (!isLastNamedChild(child)) return null;

        child = parent;
    }
}

fn isFunctionBoundary(lang: grammars.Language, node: bindings.TSNode) bool {
    const node_type = node.getType();
    if (lang.isFunction(node_type)) return true;

    // A named arrow/function expression is a boundary of its own; anonymous
    // ones in argument position stay closures and force an advisory result.
    if (lang == .typescript or lang == .tsx) {
        if (std.mem.eql(u8, node_type, "arrow_function") or std.mem.eql(u8, node_type, "function_expression")) {
            const parent = node.parent();
            return !parent.isNull() and std.mem.eql(u8, parent.getType(), "variable_declarator");
        }
    }
    return false;
}

fn isBlockingContext(lang: grammars.Language, node_type: []const u8) bool {
    if (lang.isLoopNode(node_type)) return true;
    if (lang.isSwitchNode(node_type)) return true;
    if (lang.isCatchNode(node_type)) return true;
    if (std.mem.eql(u8, node_type, "finally_clause")) return true;
    if (std.mem.eql(u8, node_type, "labeled_statement")) return true;
    if (std.mem.eql(u8, node_type, "labeled_expression")) return true;
    if (lang == .python and std.mem.eql(u8, node_type, "try_statement")) return true;
    return false;
}

/// A node is last in its block when it has no later named sibling. Comments
/// are named nodes, so a trailing comment keeps the guard advisory.
fn isLastNamedChild(node: bindings.TSNode) bool {
    const parent = node.parent();
    if (parent.isNull()) return false;
    const count = parent.namedChildCount();
    if (count == 0) return false;

    const last = parent.namedChild(count - 1);
    return last.startByte() == node.startByte() and last.endByte() == node.endByte();
}

fn isVoidCapable(lang: grammars.Language, source: []const u8, boundary: bindings.TSNode) bool {
    return switch (lang) {
        .typescript, .tsx => tsVoidCapable(source, boundary),
        .go => boundary.childByFieldName("result").isNull(),
        .zig => zigVoidCapable(source, boundary),
        .rust => boundary.childByFieldName("return_type").isNull(),
        // An early `return` is valid in every Python function.
        .python => true,
        .c_sharp => cSharpVoidCapable(source, boundary),
        else => false,
    };
}

fn cSharpVoidCapable(source: []const u8, boundary: bindings.TSNode) bool {
    const returns = boundary.childByFieldName("returns");
    const return_type = if (returns.isNull()) boundary.childByFieldName("type") else returns;
    if (return_type.isNull()) return false;
    return std.mem.eql(u8, std.mem.trim(u8, return_type.slice(source), " \t\r\n"), "void");
}

fn zigVoidCapable(source: []const u8, boundary: bindings.TSNode) bool {
    const return_type = boundary.childByFieldName("type");
    if (return_type.isNull()) return true;
    return std.mem.eql(u8, std.mem.trim(u8, return_type.slice(source), " \t\r\n"), "void");
}

fn tsVoidCapable(source: []const u8, boundary: bindings.TSNode) bool {
    const boundary_type = boundary.getType();
    const return_type = boundary.childByFieldName("return_type");

    if (std.mem.eql(u8, boundary_type, "function_declaration") or
        std.mem.eql(u8, boundary_type, "method_definition"))
    {
        if (return_type.isNull()) return false;
        return isVoidAnnotation(return_type.slice(source));
    }

    // Arrow and function expressions: explicit `: void` wins; an unannotated
    // one qualifies only when its own body never returns a value.
    if (!return_type.isNull()) return isVoidAnnotation(return_type.slice(source));
    return !hasValueReturn(boundary);
}

fn isVoidAnnotation(slice: []const u8) bool {
    var trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == ':') {
        trimmed = std.mem.trim(u8, trimmed[1..], " \t\r\n");
    }
    return std.mem.eql(u8, trimmed, "void");
}

fn hasValueReturn(node: bindings.TSNode) bool {
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const child = node.namedChild(i);
        const child_type = child.getType();
        if (std.mem.eql(u8, child_type, "return_statement")) {
            if (child.namedChildCount() > 0) return true;
            continue;
        }
        if (isNestedFunctionType(child_type)) continue;
        if (hasValueReturn(child)) return true;
    }
    return false;
}

fn isNestedFunctionType(node_type: []const u8) bool {
    const nested = [_][]const u8{
        "function_declaration", "method_definition",   "arrow_function",     "function_expression",
        "function_item",        "function_definition", "closure_expression", "func_literal",
        "lambda",               "lambda_expression",
    };
    for (nested) |candidate| {
        if (std.mem.eql(u8, node_type, candidate)) return true;
    }
    return false;
}

fn isCleanBody(syntax: *const GuardSyntax, source: []const u8, if_node: bindings.TSNode) bool {
    const body = if_node.childByFieldName(syntax.body_field);
    if (body.isNull()) return false;
    if (body.namedChildCount() == 0) return false;
    return !hasCommentOrMultilineString(if_node, source);
}

fn hasCommentOrMultilineString(node: bindings.TSNode, source: []const u8) bool {
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const child = node.namedChild(i);
        const child_type = child.getType();
        if (std.mem.indexOf(u8, child_type, "comment") != null) return true;
        if (std.mem.indexOf(u8, child_type, "string") != null) {
            if (std.mem.indexOfScalar(u8, child.slice(source), '\n') != null) return true;
        }
        if (hasCommentOrMultilineString(child, source)) return true;
    }
    return false;
}

/// Builds `if (<invert>(<cond>)) <early_return>` plus the de-indented body.
/// Returns null when the body cannot be de-indented one level safely.
fn buildReplacement(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    syntax: *const GuardSyntax,
    if_node: bindings.TSNode,
) !?[]u8 {
    const condition = if_node.childByFieldName(syntax.condition_field);
    if (condition.isNull()) return null;
    const body = if_node.childByFieldName(syntax.body_field);
    if (body.isNull()) return null;

    const if_prefix = source[lineStart(source, if_node.startByte())..if_node.startByte()];
    if (std.mem.trim(u8, if_prefix, " \t").len != 0) return null;

    const body_part = (try buildBodyPart(allocator, source, lang, body, if_prefix)) orelse return null;
    defer allocator.free(body_part);

    const guard_line = try buildGuardLine(allocator, syntax, conditionText(condition, source));
    defer allocator.free(guard_line);

    const newline: []const u8 = if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else "\n";
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ guard_line, newline, body_part });
}

fn buildGuardLine(allocator: std.mem.Allocator, syntax: *const GuardSyntax, cond_text: []const u8) ![]u8 {
    if (std.mem.eql(u8, syntax.invert_prefix, "not ")) {
        return std.fmt.allocPrint(allocator, "if {s}({s}): {s}", .{ syntax.invert_prefix, cond_text, syntax.early_return });
    }
    return std.fmt.allocPrint(allocator, "if ({s}({s})) {s}", .{ syntax.invert_prefix, cond_text, syntax.early_return });
}

/// The TypeScript grammar wraps the condition in a `parenthesized_expression`
/// whose slice keeps the `if` parentheses; drop exactly that outer pair.
fn conditionText(condition: bindings.TSNode, source: []const u8) []const u8 {
    const text = condition.slice(source);
    if (std.mem.eql(u8, condition.getType(), "parenthesized_expression") and
        text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')')
    {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn buildBodyPart(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    body: bindings.TSNode,
    if_prefix: []const u8,
) !?[]u8 {
    const body_text = body.slice(source);
    if (std.mem.startsWith(u8, body_text, "{")) {
        return try deindentBracedBody(allocator, body_text, if_prefix);
    }
    if (lang != .python) return null;
    return try deindentPythonBody(allocator, source, body, body_text, if_prefix);
}

fn deindentBracedBody(
    allocator: std.mem.Allocator,
    body_text: []const u8,
    if_prefix: []const u8,
) !?[]u8 {
    const first_newline = std.mem.indexOfScalar(u8, body_text, '\n') orelse return null;

    // The opening brace must stand alone so nothing is dropped with its line.
    for (body_text[0..first_newline]) |ch| {
        if (ch != '{' and ch != ' ' and ch != '\t' and ch != '\r') return null;
    }

    const last_newline = std.mem.lastIndexOfScalar(u8, body_text, '\n') orelse return null;
    if (last_newline <= first_newline) return null;

    // The closing brace must stand alone as well.
    if (!std.mem.eql(u8, std.mem.trim(u8, body_text[last_newline + 1 ..], " \t\r"), "}")) {
        return null;
    }

    var interior_end = last_newline;
    if (interior_end > first_newline + 1 and body_text[interior_end - 1] == '\r') interior_end -= 1;

    const interior = body_text[first_newline + 1 .. interior_end];
    return try deindentLines(allocator, interior, if_prefix);
}

fn deindentPythonBody(
    allocator: std.mem.Allocator,
    source: []const u8,
    body: bindings.TSNode,
    body_text: []const u8,
    if_prefix: []const u8,
) !?[]u8 {
    const body_start: usize = body.startByte();
    const indent = source[lineStart(source, body_start)..body_start];
    if (std.mem.trim(u8, indent, " \t").len != 0) return null;
    if (!std.mem.startsWith(u8, indent, if_prefix)) return null;

    const unit = indent[if_prefix.len..];
    if (unit.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // The first body line's indentation lives before the block node, so the
    // rewritten line reuses `if_prefix`; later lines are de-indented in text.
    try out.appendSlice(allocator, if_prefix);

    var lines = std.mem.splitScalar(u8, body_text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            try out.appendSlice(allocator, line);
            first = false;
            continue;
        }
        try out.append(allocator, '\n');
        if (isBlankLine(line)) {
            try out.appendSlice(allocator, line);
            continue;
        }
        if (!std.mem.startsWith(u8, line, unit)) return null;
        try out.appendSlice(allocator, line[unit.len..]);
    }
    return try out.toOwnedSlice(allocator);
}

fn deindentLines(allocator: std.mem.Allocator, text: []const u8, if_prefix: []const u8) !?[]u8 {
    if (text.len == 0) return null;

    // The first non-blank line fixes the de-indent unit; every other non-blank
    // line must still carry it.
    var unit: []const u8 = undefined;
    {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var found = false;
        while (lines.next()) |line| {
            if (isBlankLine(line)) continue;
            const prefix = leadingWhitespace(line);
            if (!std.mem.startsWith(u8, prefix, if_prefix)) return null;
            unit = prefix[if_prefix.len..];
            found = true;
            break;
        }
        if (!found or unit.len == 0) return null;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        if (isBlankLine(line)) {
            try out.appendSlice(allocator, line);
            continue;
        }
        if (!std.mem.startsWith(u8, line, unit)) return null;
        try out.appendSlice(allocator, line[unit.len..]);
    }
    return try out.toOwnedSlice(allocator);
}

fn lineStart(source: []const u8, offset: usize) usize {
    var i = @min(offset, source.len);
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

fn leadingWhitespace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn matchesAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.eql(u8, haystack, needle)) return true;
    }
    return false;
}

const ParsedSource = struct {
    tree: bindings.Tree,
    root: bindings.TSNode,

    fn deinit(self: *ParsedSource) void {
        self.tree.deinit();
    }
};

fn parseSource(source: []const u8, lang: grammars.Language) !ParsedSource {
    const ts_lang = lang.getTsLanguage() orelse return error.LanguageNotAvailable;
    var parser = try bindings.getThreadParser();
    if (!parser.setLanguage(ts_lang)) return error.SetLanguageFailed;
    var tree = try parser.parseString(source);
    return .{ .tree = tree, .root = tree.rootNode() };
}

fn collectGuards(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) ![]proposal.Proposal {
    var parsed = try parseSource(source, lang);
    defer parsed.deinit();
    return collect(allocator, source, lang, parsed.root);
}

fn deinitGuards(allocator: std.mem.Allocator, proposals: []proposal.Proposal) void {
    for (proposals) |p| p.deinit(allocator);
    allocator.free(proposals);
}

/// Asserts exactly one applicable guard proposal and that applying it yields
/// `expected` byte-for-byte.
fn expectGuarded(source: []const u8, lang: grammars.Language, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const proposals = try collectGuards(allocator, source, lang);
    defer deinitGuards(allocator, proposals);
    try std.testing.expectEqual(@as(usize, 1), proposals.len);

    const sorted = try allocator.dupe(edits.Edit, proposals[0].edits);
    defer allocator.free(sorted);
    edits.sortEdits(sorted);

    const output = try edits.apply(allocator, source, sorted);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

fn expectNoGuards(source: []const u8, lang: grammars.Language) !void {
    const allocator = std.testing.allocator;
    const proposals = try collectGuards(allocator, source, lang);
    defer deinitGuards(allocator, proposals);
    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

fn findFirstNode(node: bindings.TSNode, node_type: []const u8) ?bindings.TSNode {
    if (!node.isNull()) {
        if (std.mem.eql(u8, node.getType(), node_type)) return node;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (findFirstNode(node.namedChild(i), node_type)) |found| return found;
        }
    }
    return null;
}

test "guard grammar fields resolve against embedded grammars" {
    const samples = [_]struct {
        lang: grammars.Language,
        source: []const u8,
        body_type: []const u8,
    }{
        .{
            .lang = .typescript,
            .source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n",
            .body_type = "statement_block",
        },
        .{
            .lang = .tsx,
            .source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n",
            .body_type = "statement_block",
        },
        .{
            .lang = .go,
            .source = "package main\n\nfunc process(user User) {\n    if user.IsActive {\n        sendEmail(user)\n    }\n}\n",
            .body_type = "block",
        },
        .{
            .lang = .zig,
            .source = "fn process(user: User) void {\n    if (user.is_active) {\n        send_email(user);\n    }\n}\n",
            .body_type = "block_expression",
        },
        .{
            .lang = .rust,
            .source = "fn process(user: &User) {\n    if user.is_active {\n        send_email(user);\n    }\n}\n",
            .body_type = "block",
        },
        .{
            .lang = .python,
            .source = "def process(user):\n    if user.is_active:\n        send_email(user)\n",
            .body_type = "block",
        },
        .{
            .lang = .c_sharp,
            .source = "class Service {\n    void Process(User user) {\n        if (user.IsActive) {\n            SendEmail(user);\n        }\n    }\n}\n",
            .body_type = "block",
        },
    };

    for (samples) |sample| {
        var parsed = try parseSource(sample.source, sample.lang);
        defer parsed.deinit();

        const syntax = syntaxFor(sample.lang).?;
        const if_node = findFirstNode(parsed.root, syntax.if_nodes[0]) orelse return error.NoIfNode;

        const condition = if_node.childByFieldName(syntax.condition_field);
        try std.testing.expect(!condition.isNull());

        const body = if_node.childByFieldName(syntax.body_field);
        try std.testing.expect(!body.isNull());
        try std.testing.expectEqualStrings(sample.body_type, body.getType());

        if (syntax.else_field.len > 0) {
            try std.testing.expect(if_node.childByFieldName(syntax.else_field).isNull());
        }
        try std.testing.expect(!hasElseBranch(syntax, if_node));
        try std.testing.expect(isFunctionBoundary(sample.lang, enclosingFunction(sample.lang, if_node).?));
    }

    for (supportedLanguages()) |lang| {
        try std.testing.expect(syntaxFor(lang) != null);
    }
}

test "guard extraction flattens tail-position void function" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";
    const expected = "function process(user: User): void {\n  if (!(user.isActive)) { return; }\n  sendEmail(user);\n}\n";
    try expectGuarded(source, .typescript, expected);
}

test "statement after the if keeps it advisory" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n  logDone();\n}\n";
    try expectNoGuards(source, .typescript);
}

test "statement after an enclosing block keeps it advisory" {
    const source = "function process(user: User): void {\n  {\n    if (user.isActive) {\n      sendEmail(user);\n    }\n  }\n  logDone();\n}\n";
    try expectNoGuards(source, .typescript);
}

test "if inside for loop stays advisory" {
    const source = "function process(users: User[]): void {\n  for (const user of users) {\n    if (user.isActive) {\n      sendEmail(user);\n    }\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "if inside switch case stays advisory" {
    const source = "function process(x: number): void {\n  switch (x) {\n    case 1: {\n      if (check(x)) {\n        sendEmail(x);\n      }\n    }\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "if inside catch clause stays advisory" {
    const source = "function process(): void {\n  try {\n    risky();\n  } catch (err) {\n    if (err) {\n      recover();\n    }\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "non-void function stays advisory" {
    const source = "function process(user: User): string {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "if with else stays advisory" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  } else {\n    logDone();\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "if containing comments stays advisory" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    // notify the user\n    sendEmail(user);\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "comment after the if keeps it advisory" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n  // done\n}\n";
    try expectNoGuards(source, .typescript);
}

test "multi-line string in body stays advisory" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    const msg = `hello\n    world`;\n    sendEmail(user, msg);\n  }\n}\n";
    try expectNoGuards(source, .typescript);
}

test "CRLF input keeps CRLF; missing trailing newline preserved" {
    const source = "function f(): void {\r\n  if (a) {\r\n    b();\r\n  }\r\n}";
    const expected = "function f(): void {\r\n  if (!(a)) { return; }\r\n  b();\r\n}";
    try expectGuarded(source, .typescript, expected);
}

test "nested eligible ifs keep only the innermost" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    if (user.hasPaid) {\n      sendEmail(user);\n    }\n  }\n}\n";
    const expected = "function process(user: User): void {\n  if (user.isActive) {\n    if (!(user.hasPaid)) { return; }\n    sendEmail(user);\n  }\n}\n";
    try expectGuarded(source, .typescript, expected);
}

test "unannotated arrow function without value returns stays eligible" {
    const source = "const process = (user: User): void => {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n};\n";
    const expected = "const process = (user: User): void => {\n  if (!(user.isActive)) { return; }\n  sendEmail(user);\n};\n";
    try expectGuarded(source, .typescript, expected);
}

test "arrow function returning a value stays advisory" {
    const source = "const process = (user: User) => {\n  if (user.isActive) {\n    return sendEmail(user);\n  }\n};\n";
    try expectNoGuards(source, .typescript);
}

test "arrow function in argument position stays advisory" {
    const source = "function f(): void {\n  call((): void => {\n    if (a) {\n      b();\n    }\n  });\n}\n";
    try expectNoGuards(source, .typescript);
}

test "tsx files use the same guard transform" {
    const source = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";
    const expected = "function process(user: User): void {\n  if (!(user.isActive)) { return; }\n  sendEmail(user);\n}\n";
    try expectGuarded(source, .tsx, expected);
}

test "guard extraction flattens tail-position void Go function" {
    const source = "package main\n\nfunc process(user User) {\n    if user.IsActive {\n        sendEmail(user)\n    }\n}\n";
    const expected = "package main\n\nfunc process(user User) {\n    if (!(user.IsActive)) { return }\n    sendEmail(user)\n}\n";
    try expectGuarded(source, .go, expected);
}

test "Go statement after the if stays advisory" {
    const source = "package main\n\nfunc process(user User) {\n    if user.IsActive {\n        sendEmail(user)\n    }\n    logDone()\n}\n";
    try expectNoGuards(source, .go);
}

test "Go if inside for loop stays advisory" {
    const source = "package main\n\nfunc process(users []User) {\n    for _, user := range users {\n        if user.IsActive {\n            sendEmail(user)\n        }\n    }\n}\n";
    try expectNoGuards(source, .go);
}

test "Go if inside expression switch stays advisory" {
    const source = "package main\n\nfunc process(x int) {\n    switch x {\n    case 1:\n        if check(x) {\n            sendEmail(x)\n        }\n    }\n}\n";
    try expectNoGuards(source, .go);
}

test "Go if inside type switch stays advisory" {
    const source = "package main\n\nfunc process(v any) {\n    switch v.(type) {\n    case int:\n        if check(v) {\n            sendEmail(v)\n        }\n    }\n}\n";
    try expectNoGuards(source, .go);
}

test "Go if inside select statement stays advisory" {
    const source = "package main\n\nfunc process(ch chan int) {\n    select {\n    case <-ch:\n        if check(ch) {\n            sendEmail(ch)\n        }\n    }\n}\n";
    try expectNoGuards(source, .go);
}

test "Go function with result stays advisory" {
    const source = "package main\n\nfunc process(user User) error {\n    if user.IsActive {\n        sendEmail(user)\n    }\n}\n";
    try expectNoGuards(source, .go);
}

test "Go if with initializer stays advisory" {
    const source = "package main\n\nfunc process() {\n    if err := sendEmail(); err != nil {\n        logDone()\n    }\n}\n";
    try expectNoGuards(source, .go);
}

test "guard extraction flattens tail-position void Zig function" {
    const source = "fn process(user: User) void {\n    if (user.is_active) {\n        send_email(user);\n    }\n}\n";
    const expected = "fn process(user: User) void {\n    if (!(user.is_active)) { return; }\n    send_email(user);\n}\n";
    try expectGuarded(source, .zig, expected);
}

test "Zig statement after the if stays advisory" {
    const source = "fn process(user: User) void {\n    if (user.is_active) {\n        send_email(user);\n    }\n    log_done();\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig if inside for loop stays advisory" {
    const source = "fn process(users: []const User) void {\n    for (users) |user| {\n        if (user.is_active) {\n            send_email(user);\n        }\n    }\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig if inside while loop stays advisory" {
    const source = "fn process(flag: bool) void {\n    while (flag) {\n        if (check()) {\n            send_email();\n        }\n    }\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig if inside switch prong stays advisory" {
    const source = "fn classify(value: u32) void {\n    switch (value) {\n        1 => {\n            if (check(value)) {\n                send(value);\n            }\n        },\n        else => {},\n    }\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig if expression assigned to a value stays advisory" {
    const source = "fn pick(flag: bool) u32 {\n    const value = if (flag) 1 else 2;\n    return value;\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig error-union return type stays advisory" {
    const source = "fn process(user: User) !void {\n    if (user.is_active) {\n        send_email(user);\n    }\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig if with payload capture stays advisory" {
    const source = "fn process(opt: ?u8) void {\n    if (opt) |value| {\n        send(value);\n    }\n}\n";
    try expectNoGuards(source, .zig);
}

test "Zig if with inline else stays advisory" {
    const source = "fn process(flag: bool) void {\n    if (flag) {\n        send_email();\n    } else {\n        log_done();\n    }\n}\n";
    try expectNoGuards(source, .zig);
}

test "guard extraction flattens tail-position void Rust function" {
    const source = "fn process(user: &User) {\n    if user.is_active {\n        send_email(user);\n    }\n}\n";
    const expected = "fn process(user: &User) {\n    if (!(user.is_active)) { return; }\n    send_email(user);\n}\n";
    try expectGuarded(source, .rust, expected);
}

test "Rust statement after the if stays advisory" {
    const source = "fn process(user: &User) {\n    if user.is_active {\n        send_email(user);\n    }\n    log_done();\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust if inside while loop stays advisory" {
    const source = "fn process(flag: bool) {\n    while flag {\n        if check() {\n            send_email();\n        }\n    }\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust if inside match arm stays advisory" {
    const source = "fn process(value: Option<u8>) {\n    match value {\n        Some(_) => {\n            if check() {\n                send_email();\n            }\n        }\n        None => {}\n    }\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust if inside closure body stays advisory" {
    const source = "fn process() {\n    let callback = || {\n        if check() {\n            send_email();\n        }\n    };\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust function with return type stays advisory" {
    const source = "fn process(user: &User) -> bool {\n    if user.is_active {\n        send_email(user);\n    }\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust if in let initializer stays advisory" {
    const source = "fn process(flag: bool) {\n    let unit = if flag {};\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust if let stays advisory" {
    const source = "fn process(opt: Option<u8>) {\n    if let Some(value) = opt {\n        send_email(value);\n    }\n}\n";
    try expectNoGuards(source, .rust);
}

test "Rust if with else stays advisory" {
    const source = "fn process(user: &User) {\n    if user.is_active {\n        send_email(user);\n    } else {\n        log_done();\n    }\n}\n";
    try expectNoGuards(source, .rust);
}

test "guard extraction flattens tail-position Python function" {
    const source = "def process(user):\n    if user.is_active:\n        send_email(user)\n";
    const expected = "def process(user):\n    if not (user.is_active): return\n    send_email(user)\n";
    try expectGuarded(source, .python, expected);
}

test "Python multi-statement body de-indents every line" {
    const source = "def process(user):\n    if user.is_active:\n        send_email(user)\n        log_done()\n";
    const expected = "def process(user):\n    if not (user.is_active): return\n    send_email(user)\n    log_done()\n";
    try expectGuarded(source, .python, expected);
}

test "Python tab indentation de-indents by one tab" {
    const source = "def process(user):\n\tif user.is_active:\n\t\tsend_email(user)\n";
    const expected = "def process(user):\n\tif not (user.is_active): return\n\tsend_email(user)\n";
    try expectGuarded(source, .python, expected);
}

test "Python statement after the if stays advisory" {
    const source = "def process(user):\n    if user.is_active:\n        send_email(user)\n    log_done()\n";
    try expectNoGuards(source, .python);
}

test "Python if inside for body stays advisory" {
    const source = "def process(users):\n    for user in users:\n        if user.is_active:\n            send_email(user)\n";
    try expectNoGuards(source, .python);
}

test "Python if inside except block stays advisory" {
    const source = "def process():\n    try:\n        risky()\n    except Exception:\n        if check():\n            recover()\n";
    try expectNoGuards(source, .python);
}

test "Python if inside finally block stays advisory" {
    const source = "def process():\n    try:\n        risky()\n    finally:\n        if check():\n            recover()\n";
    try expectNoGuards(source, .python);
}

test "Python if in an elif chain stays advisory" {
    const source = "def process(user):\n    if user.is_active:\n        send_email(user)\n    elif user.is_vip:\n        call(user)\n";
    try expectNoGuards(source, .python);
}

test "Python if with else stays advisory" {
    const source = "def process(user):\n    if user.is_active:\n        send_email(user)\n    else:\n        log_done()\n";
    try expectNoGuards(source, .python);
}

test "Python if containing a comment stays advisory" {
    const source = "def process(user):\n    if user.is_active:\n        # notify the user\n        send_email(user)\n";
    try expectNoGuards(source, .python);
}

test "Python multi-line string in body stays advisory" {
    const source = "def process(user):\n    if user.is_active:\n        send_email(\"\"\"hello\nworld\"\"\")\n";
    try expectNoGuards(source, .python);
}

test "guard extraction flattens tail-position void C# method" {
    const source = "class Service {\n    void Process(User user) {\n        if (user.IsActive) {\n            SendEmail(user);\n        }\n    }\n}\n";
    const expected = "class Service {\n    void Process(User user) {\n        if (!(user.IsActive)) { return; }\n        SendEmail(user);\n    }\n}\n";
    try expectGuarded(source, .c_sharp, expected);
}

test "C# local function with void type is eligible" {
    const source = "class Service {\n    void Process(User user) {\n        void Local() {\n            if (user.IsActive) {\n                SendEmail(user);\n            }\n        }\n    }\n}\n";
    const expected = "class Service {\n    void Process(User user) {\n        void Local() {\n            if (!(user.IsActive)) { return; }\n            SendEmail(user);\n        }\n    }\n}\n";
    try expectGuarded(source, .c_sharp, expected);
}

test "C# statement after the if stays advisory" {
    const source = "class Service {\n    void Process(User user) {\n        if (user.IsActive) {\n            SendEmail(user);\n        }\n        LogDone();\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# async Task method stays advisory" {
    const source = "class Service {\n    async Task Process(User user) {\n        if (user.IsActive) {\n            SendEmail(user);\n        }\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# non-void method stays advisory" {
    const source = "class Service {\n    int Compute(User user) {\n        if (user.IsActive) {\n            SendEmail(user);\n        }\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# if inside catch clause stays advisory" {
    const source = "class Service {\n    void Process() {\n        try {\n            Risky();\n        } catch (Exception err) {\n            if (Check(err)) {\n                Recover();\n            }\n        }\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# if inside finally clause stays advisory" {
    const source = "class Service {\n    void Process() {\n        try {\n            Risky();\n        } finally {\n            if (Check()) {\n                Recover();\n            }\n        }\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# if inside switch case stays advisory" {
    const source = "class Service {\n    void Process(int x) {\n        switch (x) {\n            case 1: {\n                if (Check(x)) {\n                    SendEmail(x);\n                }\n            }\n        }\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# if inside lambda body stays advisory" {
    const source = "class Service {\n    void Process() {\n        Action action = () => {\n            if (Check()) {\n                SendEmail();\n            }\n        };\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}

test "C# if with else stays advisory" {
    const source = "class Service {\n    void Process(User user) {\n        if (user.IsActive) {\n            SendEmail(user);\n        } else {\n            LogDone();\n        }\n    }\n}\n";
    try expectNoGuards(source, .c_sharp);
}
