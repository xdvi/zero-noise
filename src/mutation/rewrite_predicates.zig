const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const edits = @import("edits.zig");
const grammars = @import("../treesitter/grammars.zig");
const proposal = @import("proposal.zig");

pub const rule_name = "raw-boolean";

/// Grammar vocabulary per language, verified by the probe test below.
const Syntax = struct {
    /// Statement nodes carrying an extractable condition.
    if_nodes: []const []const u8,
    /// Same-operator boolean chain node type.
    chain_node: []const u8,
    /// Property chain node type inside an operand.
    member_node: []const u8,
    /// Field holding the chain base (`user` in `user.isActive`).
    object_field: []const u8,
    /// Field holding the chain property.
    property_field: []const u8,
    /// Node type of the chain property.
    property_node: []const u8,
    /// Whether the if's parentheses are part of the condition node.
    unwrap_condition_parens: bool,
    /// Whether every root identifier must carry an explicit type annotation.
    typed_roots: bool,
    /// Function declarations the extracted predicate can be emitted before.
    scope_nodes: []const []const u8,
    /// Function scopes that cannot host an emitted function declaration.
    boundary_nodes: []const []const u8,
};

fn syntaxFor(lang: grammars.Language) ?Syntax {
    return switch (lang) {
        .typescript, .tsx => .{
            .if_nodes = &.{"if_statement"},
            .chain_node = "binary_expression",
            .member_node = "member_expression",
            .object_field = "object",
            .property_field = "property",
            .property_node = "property_identifier",
            .unwrap_condition_parens = true,
            .typed_roots = true,
            .scope_nodes = &.{"function_declaration"},
            .boundary_nodes = &.{ "method_definition", "arrow_function", "function_expression", "generator_function_declaration" },
        },
        .python => .{
            .if_nodes = &.{"if_statement"},
            .chain_node = "boolean_operator",
            .member_node = "attribute",
            .object_field = "object",
            .property_field = "attribute",
            .property_node = "identifier",
            .unwrap_condition_parens = true,
            .typed_roots = false,
            .scope_nodes = &.{"function_definition"},
            .boundary_nodes = &.{"lambda"},
        },
        else => null,
    };
}

pub fn supportedLanguages() []const grammars.Language {
    return &.{ .typescript, .tsx, .python };
}

const Root = struct {
    name: []const u8,
    type_text: ?[]const u8,
};

const Context = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    syntax: Syntax,
    proposals: std.ArrayList(proposal.Proposal) = .empty,
    used_names: std.StringHashMap(void),
    awarded_names: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Context) void {
        for (self.proposals.items) |p| p.deinit(self.allocator);
        self.proposals.deinit(self.allocator);
        self.used_names.deinit();
        for (self.awarded_names.items) |name| self.allocator.free(name);
        self.awarded_names.deinit(self.allocator);
    }

    fn appendAdvisory(self: *Context, if_node: bindings.TSNode, reason: []const u8) !void {
        const point = if_node.startPoint();
        try self.proposals.append(self.allocator, .{
            .kind = .predicate,
            .rule = try self.allocator.dupe(u8, rule_name),
            .file = try self.allocator.dupe(u8, ""),
            .line = point.row + 1,
            .col = point.column + 1,
            .message = try std.fmt.allocPrint(self.allocator, "predicate extraction skipped: {s}", .{reason}),
            .confidence = .medium,
            .naming_required = true,
            .safe_to_apply = false,
            .edits = &.{},
            .expected_hash = try self.allocator.dupe(u8, ""),
        });
    }
};

/// Extracts same-operator compound boolean conditions from `if` statements
/// into named predicate functions. Conditions that cannot be typed or that
/// use unsupported operands stay advisory.
pub fn collect(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    const syntax = syntaxFor(lang) orelse return &.{};

    var ctx = Context{
        .allocator = allocator,
        .source = source,
        .lang = lang,
        .syntax = syntax,
        .used_names = std.StringHashMap(void).init(allocator),
    };
    defer ctx.deinit();

    if (root.isNull()) return &.{};
    try collectIdentifiers(&ctx, root);
    try walkAnchors(&ctx, root);

    return try ctx.proposals.toOwnedSlice(allocator);
}

fn walkAnchors(ctx: *Context, node: bindings.TSNode) anyerror!void {
    if (node.isNull()) return;

    for (ctx.syntax.if_nodes) |if_type| {
        if (std.mem.eql(u8, node.getType(), if_type)) {
            try collectCondition(ctx, node);
            break;
        }
    }

    var i: u32 = 0;
    const count = node.namedChildCount();
    while (i < count) : (i += 1) {
        try walkAnchors(ctx, node.namedChild(i));
    }
}

fn collectCondition(ctx: *Context, if_node: bindings.TSNode) !void {
    const source = ctx.source;
    const declared_condition = if_node.childByFieldName("condition");
    if (declared_condition.isNull()) return;

    var condition = declared_condition;
    if (ctx.syntax.unwrap_condition_parens and
        std.mem.eql(u8, condition.getType(), "parenthesized_expression") and
        condition.namedChildCount() == 1)
    {
        condition = condition.namedChild(0);
    }

    if (!std.mem.eql(u8, condition.getType(), ctx.syntax.chain_node)) return;
    if (chainOperator(ctx, condition) == null) return;

    var operands: std.ArrayList(bindings.TSNode) = .empty;
    defer operands.deinit(ctx.allocator);

    var operator: ?[]const u8 = null;
    if (!try flattenChain(ctx, condition, &operands, &operator)) {
        return ctx.appendAdvisory(if_node, "non-uniform logical operators");
    }
    if (operands.items.len < 2) return;

    if (condition.startPoint().row != condition.endPoint().row) {
        return ctx.appendAdvisory(if_node, "condition spans multiple lines");
    }

    const condition_text = condition.slice(source);
    if (std.mem.count(u8, source, condition_text) != 1) {
        return ctx.appendAdvisory(if_node, "condition text appears more than once in the file");
    }

    const fn_node = enclosingFunction(ctx, if_node) orelse {
        return ctx.appendAdvisory(if_node, "no enclosing function declaration can host the predicate");
    };

    var roots: std.ArrayList(Root) = .empty;
    defer roots.deinit(ctx.allocator);

    for (operands.items) |operand| {
        const root_node = rootIdentifier(ctx, operand) orelse {
            const reason = if (usesThis(ctx, operand))
                "operand uses `this`"
            else
                "operand is not an identifier or property chain";
            return ctx.appendAdvisory(if_node, reason);
        };
        const name = root_node.slice(source);
        if (containsRoot(roots.items, name)) continue;

        const type_text = try resolveRootType(ctx, fn_node, name, condition.startByte());
        if (ctx.syntax.typed_roots and type_text == null) {
            const reason = try std.fmt.allocPrint(
                ctx.allocator,
                "root identifier `{s}` has no explicit type annotation",
                .{name},
            );
            defer ctx.allocator.free(reason);
            return ctx.appendAdvisory(if_node, reason);
        }
        try roots.append(ctx.allocator, .{ .name = name, .type_text = type_text });
    }

    const name = try awardPredicateName(ctx, roots.items[0].name);
    try appendExtraction(ctx, if_node, fn_node, condition, name, roots.items);
}

fn appendExtraction(
    ctx: *Context,
    if_node: bindings.TSNode,
    fn_node: bindings.TSNode,
    condition: bindings.TSNode,
    name: []const u8,
    roots: []const Root,
) !void {
    const indent = lineIndent(ctx.source, fn_node.startByte());

    var replacement: std.ArrayList(u8) = .empty;
    defer replacement.deinit(ctx.allocator);

    try replacement.appendSlice(ctx.allocator, indent);
    if (ctx.lang == .python) {
        try replacement.appendSlice(ctx.allocator, "def ");
        try replacement.appendSlice(ctx.allocator, name);
        try replacement.append(ctx.allocator, '(');
        try appendParams(ctx.allocator, &replacement, roots);
        try replacement.appendSlice(ctx.allocator, "):\n");
        try replacement.appendSlice(ctx.allocator, indent);
        try replacement.appendSlice(ctx.allocator, pythonIndentUnit(ctx, fn_node, indent.len));
        try replacement.appendSlice(ctx.allocator, "return ");
        try replacement.appendSlice(ctx.allocator, condition.slice(ctx.source));
        try replacement.append(ctx.allocator, '\n');
    } else {
        try replacement.appendSlice(ctx.allocator, "function ");
        try replacement.appendSlice(ctx.allocator, name);
        try replacement.append(ctx.allocator, '(');
        try appendParams(ctx.allocator, &replacement, roots);
        try replacement.appendSlice(ctx.allocator, "): boolean { return ");
        try replacement.appendSlice(ctx.allocator, condition.slice(ctx.source));
        try replacement.appendSlice(ctx.allocator, "; }\n");
    }

    var call: std.ArrayList(u8) = .empty;
    defer call.deinit(ctx.allocator);
    try call.appendSlice(ctx.allocator, name);
    try call.append(ctx.allocator, '(');
    try appendArgs(ctx.allocator, &call, roots);
    try call.append(ctx.allocator, ')');

    const proposal_edits = try ctx.allocator.alloc(edits.Edit, 2);
    errdefer ctx.allocator.free(proposal_edits);
    const insert_at = lineStartOffset(ctx.source, fn_node.startByte());
    proposal_edits[0] = .{
        .start = insert_at,
        .end = insert_at,
        .replacement = try ctx.allocator.dupe(u8, replacement.items),
    };
    errdefer ctx.allocator.free(proposal_edits[0].replacement);
    proposal_edits[1] = .{
        .start = condition.startByte(),
        .end = condition.endByte(),
        .replacement = try ctx.allocator.dupe(u8, call.items),
    };

    const point = if_node.startPoint();
    try ctx.proposals.append(ctx.allocator, .{
        .kind = .predicate,
        .rule = try ctx.allocator.dupe(u8, rule_name),
        .file = try ctx.allocator.dupe(u8, ""),
        .line = point.row + 1,
        .col = point.column + 1,
        .message = try std.fmt.allocPrint(
            ctx.allocator,
            "extract predicate `{s}` from raw compound boolean condition (naming required)",
            .{name},
        ),
        .confidence = .medium,
        .naming_required = true,
        .safe_to_apply = true,
        .edits = proposal_edits,
        .expected_hash = try ctx.allocator.dupe(u8, ""),
    });
}

fn appendParams(allocator: std.mem.Allocator, out: *std.ArrayList(u8), roots: []const Root) !void {
    for (roots, 0..) |root, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, root.name);
        if (root.type_text) |type_text| {
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, type_text);
        }
    }
}

fn appendArgs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), roots: []const Root) !void {
    for (roots, 0..) |root, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, root.name);
    }
}

fn containsRoot(roots: []const Root, name: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, root.name, name)) return true;
    }
    return false;
}

/// Indentation step used for the emitted Python `return`, taken from the
/// enclosing function's first body statement, falling back to four spaces.
fn pythonIndentUnit(ctx: *Context, fn_node: bindings.TSNode, fn_indent_len: usize) []const u8 {
    const body = fn_node.childByFieldName("body");
    if (!body.isNull() and body.namedChildCount() > 0) {
        const statement_indent = lineIndent(ctx.source, body.namedChild(0).startByte());
        if (statement_indent.len > fn_indent_len) return statement_indent[fn_indent_len..];
    }
    return "    ";
}

fn flattenChain(
    ctx: *Context,
    node: bindings.TSNode,
    operands: *std.ArrayList(bindings.TSNode),
    operator: *?[]const u8,
) !bool {
    if (std.mem.eql(u8, node.getType(), ctx.syntax.chain_node)) {
        const op = chainOperator(ctx, node) orelse return false;
        if (operator.*) |known| {
            if (!std.mem.eql(u8, known, op)) return false;
        } else {
            operator.* = op;
        }

        const left = node.childByFieldName("left");
        const right = node.childByFieldName("right");
        if (left.isNull() or right.isNull()) return false;
        if (!try flattenChain(ctx, left, operands, operator)) return false;
        return flattenChain(ctx, right, operands, operator);
    }

    try operands.append(ctx.allocator, node);
    return true;
}

fn chainOperator(ctx: *Context, node: bindings.TSNode) ?[]const u8 {
    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        const text = node.child(i).slice(ctx.source);
        if (std.mem.eql(u8, text, "&&") or std.mem.eql(u8, text, "||") or
            std.mem.eql(u8, text, "and") or std.mem.eql(u8, text, "or"))
        {
            return text;
        }
    }
    return null;
}

/// Resolves an operand to its root identifier, or null when the operand is
/// not a bare identifier or a non-computed property chain.
fn rootIdentifier(ctx: *Context, node: bindings.TSNode) ?bindings.TSNode {
    const t = node.getType();
    if (std.mem.eql(u8, t, "identifier")) return node;
    if (!std.mem.eql(u8, t, ctx.syntax.member_node)) return null;

    const object = node.childByFieldName(ctx.syntax.object_field);
    const property = node.childByFieldName(ctx.syntax.property_field);
    if (object.isNull() or property.isNull()) return null;
    if (!std.mem.eql(u8, property.getType(), ctx.syntax.property_node)) return null;
    return rootIdentifier(ctx, object);
}

fn usesThis(ctx: *Context, node: bindings.TSNode) bool {
    const t = node.getType();
    if (std.mem.eql(u8, t, "this") or std.mem.eql(u8, t, "super") or std.mem.eql(u8, t, "meta_property")) {
        return true;
    }
    if (!std.mem.eql(u8, t, ctx.syntax.member_node)) return false;
    const object = node.childByFieldName(ctx.syntax.object_field);
    if (object.isNull()) return false;
    return usesThis(ctx, object);
}

fn resolveRootType(
    ctx: *Context,
    fn_node: bindings.TSNode,
    name: []const u8,
    limit: u32,
) !?[]const u8 {
    if (!ctx.syntax.typed_roots) return null;

    const params = fn_node.childByFieldName("parameters");
    if (!params.isNull()) {
        var i: u32 = 0;
        while (i < params.namedChildCount()) : (i += 1) {
            const param = params.namedChild(i);
            if (std.mem.eql(u8, param.getType(), "identifier")) {
                if (std.mem.eql(u8, param.slice(ctx.source), name)) return null;
                continue;
            }
            const pattern = param.childByFieldName("pattern");
            if (pattern.isNull()) continue;
            if (!std.mem.eql(u8, pattern.slice(ctx.source), name)) continue;
            return annotationText(ctx, param.childByFieldName("type"));
        }
    }

    return findTypedLocal(ctx, fn_node, name, limit);
}

fn findTypedLocal(
    ctx: *Context,
    fn_node: bindings.TSNode,
    name: []const u8,
    limit: u32,
) ?[]const u8 {
    const body = fn_node.childByFieldName("body");
    if (body.isNull()) return null;

    var i: u32 = 0;
    while (i < body.namedChildCount()) : (i += 1) {
        const stmt = body.namedChild(i);
        const stmt_type = stmt.getType();
        if (!std.mem.eql(u8, stmt_type, "lexical_declaration") and
            !std.mem.eql(u8, stmt_type, "variable_declaration"))
        {
            continue;
        }

        var j: u32 = 0;
        while (j < stmt.namedChildCount()) : (j += 1) {
            const declarator = stmt.namedChild(j);
            if (!std.mem.eql(u8, declarator.getType(), "variable_declarator")) continue;
            if (declarator.startByte() >= limit) continue;

            const decl_name = declarator.childByFieldName("name");
            if (decl_name.isNull()) continue;
            if (!std.mem.eql(u8, decl_name.slice(ctx.source), name)) continue;
            return annotationText(ctx, declarator.childByFieldName("type"));
        }
    }
    return null;
}

fn annotationText(ctx: *Context, annotation: bindings.TSNode) ?[]const u8 {
    if (annotation.isNull()) return null;
    var text = annotation.slice(ctx.source);
    if (text.len > 0 and text[0] == ':') text = text[1..];
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn enclosingFunction(ctx: *Context, node: bindings.TSNode) ?bindings.TSNode {
    var current = node.parent();
    while (!current.isNull()) {
        const t = current.getType();
        for (ctx.syntax.scope_nodes) |scope| {
            if (std.mem.eql(u8, t, scope)) return current;
        }
        for (ctx.syntax.boundary_nodes) |boundary| {
            if (std.mem.eql(u8, t, boundary)) return null;
        }
        current = current.parent();
    }
    return null;
}

fn collectIdentifiers(ctx: *Context, node: bindings.TSNode) !void {
    if (node.isNull()) return;
    if (grammars.isIdentifierType(node.getType())) {
        try ctx.used_names.put(node.slice(ctx.source), {});
    }

    var i: u32 = 0;
    const count = node.namedChildCount();
    while (i < count) : (i += 1) {
        try collectIdentifiers(ctx, node.namedChild(i));
    }
}

fn lineIndent(source: []const u8, offset: u32) []const u8 {
    const start: usize = offset;
    if (start > source.len) return "";
    var line_start = start;
    while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}
    const prefix = source[line_start..start];
    for (prefix) |ch| {
        if (ch != ' ' and ch != '\t') return "";
    }
    return prefix;
}

fn lineStartOffset(source: []const u8, offset: u32) u32 {
    const start: usize = offset;
    if (start > source.len) return offset;
    var line_start = start;
    while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}
    return @intCast(line_start);
}

fn awardPredicateName(ctx: *Context, first_root: []const u8) ![]u8 {
    if (ctx.lang == .python) {
        const base = try std.fmt.allocPrint(ctx.allocator, "is_{s}", .{first_root});
        defer ctx.allocator.free(base);
        return awardUniqueName(ctx, base);
    }

    const pascal = try ctx.allocator.alloc(u8, first_root.len);
    defer ctx.allocator.free(pascal);
    for (first_root, 0..) |ch, i| {
        pascal[i] = if (i == 0) std.ascii.toUpper(ch) else ch;
    }
    const base = try std.fmt.allocPrint(ctx.allocator, "is{s}", .{pascal});
    defer ctx.allocator.free(base);
    return awardUniqueName(ctx, base);
}

fn awardUniqueName(ctx: *Context, base: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        const candidate = if (attempt == 0)
            try ctx.allocator.dupe(u8, base)
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ base, attempt + 1 });

        if (!nameTaken(ctx, candidate)) {
            try ctx.awarded_names.append(ctx.allocator, candidate);
            return candidate;
        }
        ctx.allocator.free(candidate);
    }
    return error.NameExhausted;
}

fn nameTaken(ctx: *Context, candidate: []const u8) bool {
    if (ctx.used_names.contains(candidate)) return true;
    for (ctx.awarded_names.items) |awarded| {
        if (std.mem.eql(u8, awarded, candidate)) return true;
    }
    return false;
}

fn collectForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) ![]proposal.Proposal {
    const ts_lang = lang.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    defer bindings.deinitThreadParser();
    try std.testing.expect(parser.setLanguage(ts_lang));

    var tree = try parser.parseString(source);
    defer tree.deinit();
    try std.testing.expect(!tree.rootNode().hasError());

    return collect(allocator, source, lang, tree.rootNode());
}

fn deinitProposals(allocator: std.mem.Allocator, proposals: []proposal.Proposal) void {
    for (proposals) |p| p.deinit(allocator);
    allocator.free(proposals);
}

fn applyProposal(
    allocator: std.mem.Allocator,
    source: []const u8,
    p: proposal.Proposal,
) ![]u8 {
    const sorted = try allocator.dupe(edits.Edit, p.edits);
    defer allocator.free(sorted);
    edits.sortEdits(sorted);
    return edits.apply(allocator, source, sorted);
}

test "probe typescript predicate node types" {
    const source =
        \\function isReadyFor(user: User, config: Config): boolean {
        \\  const threshold: number = 3;
        \\  if (user.isActive && user.hasPaid && config.sorted) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;
    const ts_lang = grammars.Language.typescript.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    defer bindings.deinitThreadParser();
    try std.testing.expect(parser.setLanguage(ts_lang));

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const fn_decl = tree.rootNode().namedChild(0);
    try std.testing.expectEqualStrings("function_declaration", fn_decl.getType());

    const params = fn_decl.childByFieldName("parameters");
    try std.testing.expectEqualStrings("formal_parameters", params.getType());
    const param = params.namedChild(0);
    try std.testing.expectEqualStrings("required_parameter", param.getType());
    try std.testing.expectEqualStrings("user", param.childByFieldName("pattern").slice(source));
    try std.testing.expectEqualStrings(": User", param.childByFieldName("type").slice(source));

    const body = fn_decl.childByFieldName("body");
    const decl = body.namedChild(0);
    try std.testing.expectEqualStrings("lexical_declaration", decl.getType());
    const declarator = decl.namedChild(0);
    try std.testing.expectEqualStrings("variable_declarator", declarator.getType());
    try std.testing.expectEqualStrings("threshold", declarator.childByFieldName("name").slice(source));
    try std.testing.expectEqualStrings(": number", declarator.childByFieldName("type").slice(source));

    const if_node = body.namedChild(1);
    try std.testing.expectEqualStrings("if_statement", if_node.getType());
    const condition = if_node.childByFieldName("condition");
    try std.testing.expectEqualStrings("parenthesized_expression", condition.getType());
    try std.testing.expectEqual(@as(u32, 1), condition.namedChildCount());

    const chain = condition.namedChild(0);
    try std.testing.expectEqualStrings("binary_expression", chain.getType());
    const left = chain.childByFieldName("left");
    const right = chain.childByFieldName("right");
    try std.testing.expectEqualStrings("user.isActive && user.hasPaid", left.slice(source));
    try std.testing.expectEqualStrings("config.sorted", right.slice(source));
    try std.testing.expectEqualStrings("&&", chain.child(1).slice(source));

    const member = left.childByFieldName("left");
    try std.testing.expectEqualStrings("member_expression", member.getType());
    try std.testing.expectEqualStrings("user", member.childByFieldName("object").slice(source));
    try std.testing.expectEqualStrings("isActive", member.childByFieldName("property").slice(source));
    try std.testing.expectEqualStrings("property_identifier", member.childByFieldName("property").getType());
}

test "extracts sorted-and-two-flag condition with annotated params" {
    const allocator = std.testing.allocator;
    const source =
        \\function isReadyFor(user: User, config: Config): boolean {
        \\  if (user.isActive && user.hasPaid && config.sorted) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
        \\
    ;
    const expected =
        \\function isUser(user: User, config: Config): boolean { return user.isActive && user.hasPaid && config.sorted; }
        \\function isReadyFor(user: User, config: Config): boolean {
        \\  if (isUser(user, config)) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.predicate, p.kind);
    try std.testing.expectEqualStrings("raw-boolean", p.rule);
    try std.testing.expectEqual(proposal.Confidence.medium, p.confidence);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(p.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 2), p.edits.len);
    try std.testing.expectEqual(@as(u32, 2), p.line);
    try std.testing.expectEqual(@as(u32, 3), p.col);
    try std.testing.expect(std.mem.indexOf(u8, p.message, "isUser") != null);

    const output = try applyProposal(allocator, source, p);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "mixed && and || stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(user: User, config: Config): boolean {
        \\  if (user.isActive && user.hasPaid || config.sorted) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expectEqual(@as(usize, 0), proposals[0].edits.len);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "predicate extraction skipped") != null);
}

test "operand with function call stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(user: User): boolean {
        \\  if (user.isActive && isPaid(user)) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "identifier or property chain") != null);
}

test "unannotated parameter stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(user): boolean {
        \\  if (user.isActive && user.hasPaid) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "explicit type annotation") != null);
}

test "this-based operand stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(): boolean {
        \\  if (this.isActive && this.hasPaid) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "this") != null);
}

test "name collision appends suffix" {
    const allocator = std.testing.allocator;
    const source =
        \\function isUser(user: User): boolean {
        \\  return true;
        \\}
        \\
        \\function resolve(user: User): boolean {
        \\  if (user.isActive && user.hasPaid) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
        \\
    ;
    const expected_marker = "function isUser2(user: User): boolean { return user.isActive && user.hasPaid; }\nfunction resolve(user: User): boolean {";

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "isUser2") != null);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, expected_marker) != null);
}

test "annotated variable declaration resolves the root identifier" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(): boolean {
        \\  const user: User = loadUser();
        \\  if (user.isActive && user.hasPaid) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;
    const expected =
        \\function isUser(user: User): boolean { return user.isActive && user.hasPaid; }
        \\function resolve(): boolean {
        \\  const user: User = loadUser();
        \\  if (isUser(user)) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "condition reused elsewhere stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(user: User): boolean {
        \\  if (user.isActive && user.hasPaid) {
        \\    return true;
        \\  }
        \\  return user.isActive && user.hasPaid;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "more than once") != null);
}

test "non-chain conditions yield no proposal" {
    const allocator = std.testing.allocator;
    const source =
        \\function resolve(user: User): boolean {
        \\  if (user.isActive) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "probe python predicate node types" {
    const source =
        \\def is_ready(user, config):
        \\    threshold = 3
        \\    if user.is_active and user.has_paid and config.sorted:
        \\        return True
        \\    return False
    ;
    const py_lang = grammars.Language.python.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    defer bindings.deinitThreadParser();
    try std.testing.expect(parser.setLanguage(py_lang));

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const fn_def = tree.rootNode().namedChild(0);
    try std.testing.expectEqualStrings("function_definition", fn_def.getType());
    try std.testing.expectEqualStrings("parameters", fn_def.childByFieldName("parameters").getType());

    const body = fn_def.childByFieldName("body");
    try std.testing.expectEqualStrings("block", body.getType());

    const if_node = body.namedChild(1);
    try std.testing.expectEqualStrings("if_statement", if_node.getType());
    const condition = if_node.childByFieldName("condition");
    try std.testing.expectEqualStrings("boolean_operator", condition.getType());

    const left = condition.childByFieldName("left");
    const right = condition.childByFieldName("right");
    try std.testing.expectEqualStrings("user.is_active and user.has_paid", left.slice(source));
    try std.testing.expectEqualStrings("config.sorted", right.slice(source));
    try std.testing.expectEqualStrings("and", condition.child(1).slice(source));

    const attribute = left.childByFieldName("left");
    try std.testing.expectEqualStrings("attribute", attribute.getType());
    try std.testing.expectEqualStrings("user", attribute.childByFieldName("object").slice(source));
    try std.testing.expectEqualStrings("is_active", attribute.childByFieldName("attribute").slice(source));
}

test "extracts python predicate before the enclosing function" {
    const allocator = std.testing.allocator;
    const source =
        \\def is_ready(user):
        \\    if user.is_active and user.has_paid:
        \\        return True
        \\    return False
        \\
    ;
    const expected =
        \\def is_user(user):
        \\    return user.is_active and user.has_paid
        \\def is_ready(user):
        \\    if is_user(user):
        \\        return True
        \\    return False
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.predicate, p.kind);
    try std.testing.expectEqualStrings("raw-boolean", p.rule);
    try std.testing.expectEqual(proposal.Confidence.medium, p.confidence);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(p.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 2), p.edits.len);
    try std.testing.expectEqual(@as(u32, 2), p.line);
    try std.testing.expectEqual(@as(u32, 5), p.col);
    try std.testing.expect(std.mem.indexOf(u8, p.message, "is_user") != null);

    const output = try applyProposal(allocator, source, p);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "python nested predicate keeps body indentation" {
    const allocator = std.testing.allocator;
    const source =
        \\def outer(user):
        \\    def inner(flag):
        \\        if user.is_active and flag:
        \\            return True
        \\        return False
        \\    return inner
        \\
    ;
    const expected =
        \\def outer(user):
        \\    def is_user(user, flag):
        \\        return user.is_active and flag
        \\    def inner(flag):
        \\        if is_user(user, flag):
        \\            return True
        \\        return False
        \\    return inner
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "python await operand stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\async def loader(user):
        \\    if user.is_active and await user.fetch_flag():
        \\        return True
        \\    return False
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expectEqual(@as(usize, 0), proposals[0].edits.len);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "identifier or property chain") != null);
}

test "python mixed operators stay advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\def evaluate(user, config):
        \\    if user.is_active and config.sorted or user.is_admin:
        \\        return True
        \\    return False
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "non-uniform logical operators") != null);
}
