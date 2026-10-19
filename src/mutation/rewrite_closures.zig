const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const edits = @import("edits.zig");
const grammars = @import("../treesitter/grammars.zig");
const proposal = @import("proposal.zig");

pub const rule_name = "long-closure";
pub const max_closure_len = 80;

/// Closure node types per language, verified by the probe test below.
const Syntax = struct {
    closure_nodes: []const []const u8,
    /// Node holding call arguments around a closure.
    argument_nodes: []const []const u8,
    /// Property access node type used by safety checks.
    member_node: []const u8,
    /// Statement containers that can host an emitted function declaration.
    host_nodes: []const []const u8,
};

fn syntaxFor(lang: grammars.Language) ?Syntax {
    return switch (lang) {
        .typescript, .tsx => .{
            .closure_nodes = &.{ "arrow_function", "function_expression" },
            .argument_nodes = &.{"arguments"},
            .member_node = "member_expression",
            .host_nodes = &.{ "statement_block", "program" },
        },
        .python => .{
            .closure_nodes = &.{"lambda"},
            .argument_nodes = &.{"argument_list"},
            .member_node = "attribute",
            .host_nodes = &.{ "block", "module" },
        },
        else => null,
    };
}

pub fn supportedLanguages() []const grammars.Language {
    return &.{ .typescript, .tsx, .python };
}

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

    fn appendAdvisory(self: *Context, closure: bindings.TSNode, reason: []const u8) !void {
        const point = closure.startPoint();
        try self.proposals.append(self.allocator, .{
            .kind = .closure,
            .rule = try self.allocator.dupe(u8, rule_name),
            .file = try self.allocator.dupe(u8, ""),
            .line = point.row + 1,
            .col = point.column + 1,
            .message = try std.fmt.allocPrint(self.allocator, "closure extraction skipped: {s}", .{reason}),
            .confidence = .medium,
            .naming_required = true,
            .safe_to_apply = false,
            .edits = &.{},
            .expected_hash = try self.allocator.dupe(u8, ""),
        });
    }
};

/// Extracts long inline closures used as call arguments into named function
/// declarations. Closures that capture `this`/`arguments`/`super`/`new.target`,
/// or that are async or contain `await`/`yield`, stay advisory.
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
    try walkClosures(&ctx, root);

    return try ctx.proposals.toOwnedSlice(allocator);
}

fn walkClosures(ctx: *Context, node: bindings.TSNode) anyerror!void {
    if (node.isNull()) return;

    for (ctx.syntax.closure_nodes) |closure_type| {
        if (std.mem.eql(u8, node.getType(), closure_type)) {
            try collectClosure(ctx, node);
            break;
        }
    }

    var i: u32 = 0;
    const count = node.namedChildCount();
    while (i < count) : (i += 1) {
        try walkClosures(ctx, node.namedChild(i));
    }
}

fn collectClosure(ctx: *Context, closure: bindings.TSNode) !void {
    const length = closure.endByte() - closure.startByte();
    if (length <= max_closure_len) return;
    if (!isInsideCallArguments(ctx, closure)) return;

    if (ctx.lang == .python) {
        const body = closure.childByFieldName("body");
        if (body.isNull()) return;
        if (body.startPoint().row != body.endPoint().row) {
            return ctx.appendAdvisory(closure, "closure body spans multiple lines");
        }
    } else {
        if (isAsync(ctx, closure)) {
            return ctx.appendAdvisory(closure, "closure is async");
        }
        if (forbiddenConstruct(ctx, closure)) |reason| {
            return ctx.appendAdvisory(closure, reason);
        }
    }

    const statement = containingStatement(ctx, closure) orelse {
        return ctx.appendAdvisory(closure, "containing statement cannot host a function declaration");
    };

    const name = try awardClosureName(ctx);
    try appendExtraction(ctx, statement, closure, name);
}

fn isAsync(ctx: *Context, closure: bindings.TSNode) bool {
    var i: u32 = 0;
    const count = closure.childCount();
    while (i < count) : (i += 1) {
        const child = closure.child(i);
        if (child.isNamed()) continue;
        if (std.mem.eql(u8, child.slice(ctx.source), "async")) return true;
    }
    return false;
}

fn forbiddenConstruct(ctx: *Context, node: bindings.TSNode) ?[]const u8 {
    if (node.isNull()) return null;

    const node_type = node.getType();
    if (std.mem.eql(u8, node_type, "this")) return "closure uses `this`";
    if (std.mem.eql(u8, node_type, "super")) return "closure uses `super`";
    if (std.mem.eql(u8, node_type, "meta_property")) return "closure uses `new.target`";
    if (std.mem.eql(u8, node_type, "await_expression")) return "closure contains `await`";
    if (std.mem.eql(u8, node_type, "yield_expression")) return "closure contains `yield`";
    if (std.mem.eql(u8, node_type, "identifier") and std.mem.eql(u8, node.slice(ctx.source), "arguments")) {
        return "closure uses `arguments`";
    }

    var i: u32 = 0;
    const count = node.namedChildCount();
    while (i < count) : (i += 1) {
        if (forbiddenConstruct(ctx, node.namedChild(i))) |reason| return reason;
    }
    return null;
}

fn isInsideCallArguments(ctx: *Context, closure: bindings.TSNode) bool {
    var current = closure.parent();
    while (!current.isNull()) {
        const node_type = current.getType();
        for (ctx.syntax.argument_nodes) |argument_node| {
            if (std.mem.eql(u8, node_type, argument_node)) return true;
        }
        for (ctx.syntax.host_nodes) |host_node| {
            if (std.mem.eql(u8, node_type, host_node)) return false;
        }
        if (std.mem.eql(u8, node_type, "function_declaration") or
            std.mem.eql(u8, node_type, "method_definition") or
            std.mem.eql(u8, node_type, "variable_declarator") or
            std.mem.eql(u8, node_type, "function_expression") or
            std.mem.eql(u8, node_type, "arrow_function") or
            std.mem.eql(u8, node_type, "class_body"))
        {
            return false;
        }
        current = current.parent();
    }
    return false;
}

/// Highest ancestor that is a direct child of a statement container.
fn containingStatement(ctx: *Context, closure: bindings.TSNode) ?bindings.TSNode {
    var current = closure;
    while (true) {
        const parent = current.parent();
        if (parent.isNull()) return null;

        const parent_type = parent.getType();
        for (ctx.syntax.host_nodes) |host_node| {
            if (std.mem.eql(u8, parent_type, host_node)) return current;
        }
        if (std.mem.eql(u8, parent_type, "class_body") or
            std.mem.eql(u8, parent_type, "class_declaration") or
            std.mem.eql(u8, parent_type, "class"))
        {
            return null;
        }
        current = parent;
    }
}

fn appendExtraction(
    ctx: *Context,
    statement: bindings.TSNode,
    closure: bindings.TSNode,
    name: []const u8,
) !void {
    const body = closureBody(closure) orelse return;
    const statement_indent = lineIndent(ctx.source, statement.startByte());

    var replacement: std.ArrayList(u8) = .empty;
    defer replacement.deinit(ctx.allocator);

    if (ctx.lang == .python) {
        try replacement.appendSlice(ctx.allocator, statement_indent);
        try replacement.appendSlice(ctx.allocator, "def ");
        try replacement.appendSlice(ctx.allocator, name);
        try appendClosureParams(ctx, &replacement, closure);
        try replacement.appendSlice(ctx.allocator, ":\n");
        try replacement.appendSlice(ctx.allocator, statement_indent);
        try replacement.appendSlice(ctx.allocator, pythonIndentUnit(ctx, statement));
        try replacement.appendSlice(ctx.allocator, "return ");
        try replacement.appendSlice(ctx.allocator, body.slice(ctx.source));
        try replacement.append(ctx.allocator, '\n');
    } else {
        const is_block = std.mem.eql(u8, body.getType(), "statement_block");
        try replacement.appendSlice(ctx.allocator, statement_indent);
        try replacement.appendSlice(ctx.allocator, "function ");
        try replacement.appendSlice(ctx.allocator, name);
        try appendClosureParams(ctx, &replacement, closure);
        try replacement.append(ctx.allocator, ' ');
        if (is_block) {
            try replacement.appendSlice(ctx.allocator, body.slice(ctx.source));
        } else {
            try replacement.appendSlice(ctx.allocator, "{ return ");
            try replacement.appendSlice(ctx.allocator, body.slice(ctx.source));
            try replacement.appendSlice(ctx.allocator, "; }");
        }
        try replacement.append(ctx.allocator, '\n');
    }

    const proposal_edits = try ctx.allocator.alloc(edits.Edit, 2);
    errdefer ctx.allocator.free(proposal_edits);
    const insert_at = lineStartOffset(ctx.source, statement.startByte());
    proposal_edits[0] = .{
        .start = insert_at,
        .end = insert_at,
        .replacement = try ctx.allocator.dupe(u8, replacement.items),
    };
    errdefer ctx.allocator.free(proposal_edits[0].replacement);
    proposal_edits[1] = .{
        .start = closure.startByte(),
        .end = closure.endByte(),
        .replacement = try ctx.allocator.dupe(u8, name),
    };

    const point = closure.startPoint();
    try ctx.proposals.append(ctx.allocator, .{
        .kind = .closure,
        .rule = try ctx.allocator.dupe(u8, rule_name),
        .file = try ctx.allocator.dupe(u8, ""),
        .line = point.row + 1,
        .col = point.column + 1,
        .message = try std.fmt.allocPrint(
            ctx.allocator,
            "extract closure `{s}` into a named function (naming required)",
            .{name},
        ),
        .confidence = .medium,
        .naming_required = true,
        .safe_to_apply = true,
        .edits = proposal_edits,
        .expected_hash = try ctx.allocator.dupe(u8, ""),
    });
}

fn appendClosureParams(ctx: *Context, out: *std.ArrayList(u8), closure: bindings.TSNode) !void {
    var i: u32 = 0;
    const count = closure.namedChildCount();
    while (i < count) : (i += 1) {
        const child = closure.namedChild(i);
        const child_type = child.getType();
        if (std.mem.eql(u8, child_type, "formal_parameters")) {
            try out.appendSlice(ctx.allocator, child.slice(ctx.source));
            return;
        }
        if (std.mem.eql(u8, child_type, "lambda_parameters")) {
            try out.append(ctx.allocator, '(');
            try out.appendSlice(ctx.allocator, child.slice(ctx.source));
            try out.append(ctx.allocator, ')');
            return;
        }
    }

    const parameter = closure.childByFieldName("parameter");
    if (!parameter.isNull()) {
        try out.append(ctx.allocator, '(');
        try out.appendSlice(ctx.allocator, parameter.slice(ctx.source));
        try out.append(ctx.allocator, ')');
        return;
    }

    if (ctx.lang == .python) {
        try out.appendSlice(ctx.allocator, "()");
    }
}

/// Indentation step for the emitted Python `def` body, taken from the block
/// that hosts the containing statement.
fn pythonIndentUnit(ctx: *Context, statement: bindings.TSNode) []const u8 {
    const parent = statement.parent();
    if (parent.isNull()) return "    ";
    if (std.mem.eql(u8, parent.getType(), "module")) return "    ";

    const owner = parent.parent();
    if (owner.isNull()) return "    ";

    const statement_indent = lineIndent(ctx.source, statement.startByte());
    const owner_indent = lineIndent(ctx.source, owner.startByte());
    if (statement_indent.len > owner_indent.len) return statement_indent[owner_indent.len..];
    return "    ";
}

fn closureBody(closure: bindings.TSNode) ?bindings.TSNode {
    const body = closure.childByFieldName("body");
    if (!body.isNull()) return body;

    var i: u32 = 0;
    const count = closure.namedChildCount();
    while (i < count) : (i += 1) {
        const child = closure.namedChild(i);
        if (std.mem.eql(u8, child.getType(), "statement_block")) return child;
    }
    if (count > 0) return closure.namedChild(count - 1);
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

fn awardClosureName(ctx: *Context) ![]u8 {
    var index: usize = 1;
    while (index < 1000) : (index += 1) {
        const candidate = if (ctx.lang == .python)
            try std.fmt.allocPrint(ctx.allocator, "extracted_closure{d}", .{index})
        else
            try std.fmt.allocPrint(ctx.allocator, "extractedClosure{d}", .{index});
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

test "probe typescript closure node types" {
    const source =
        \\runTask((payload: TaskPayload) => {
        \\  console.log(payload.id);
        \\});
        \\
        \\register(function (event: Event) { return this.handle(event); });
        \\
        \\run(async (value: number) => { await work(value); return value; });
        \\
        \\wrap((value: number) => { return new.target === undefined ? value : 0; });
    ;
    const ts_lang = grammars.Language.typescript.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    defer bindings.deinitThreadParser();
    try std.testing.expect(parser.setLanguage(ts_lang));

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const root = tree.rootNode();
    const call = root.namedChild(0).namedChild(0);
    try std.testing.expectEqualStrings("call_expression", call.getType());
    const args = call.childByFieldName("arguments");
    try std.testing.expectEqualStrings("arguments", args.getType());
    try std.testing.expectEqual(@as(u32, 1), args.namedChildCount());

    const arrow = args.namedChild(0);
    try std.testing.expectEqualStrings("arrow_function", arrow.getType());
    try std.testing.expectEqualStrings("formal_parameters", arrow.childByFieldName("parameters").getType());
    try std.testing.expectEqualStrings("statement_block", arrow.childByFieldName("body").getType());

    const this_call = root.namedChild(1).namedChild(0);
    const fn_expr = this_call.childByFieldName("arguments").namedChild(0);
    try std.testing.expectEqualStrings("function_expression", fn_expr.getType());
    try std.testing.expectEqualStrings("formal_parameters", fn_expr.childByFieldName("parameters").getType());

    const async_call = root.namedChild(2).namedChild(0);
    const async_arrow = async_call.childByFieldName("arguments").namedChild(0);
    try std.testing.expectEqualStrings("arrow_function", async_arrow.getType());
    try std.testing.expectEqualStrings("async", async_arrow.child(0).slice(source));

    const meta_call = root.namedChild(3).namedChild(0);
    const meta_arrow = meta_call.childByFieldName("arguments").namedChild(0);
    const meta_body = meta_arrow.childByFieldName("body");
    const return_stmt = meta_body.namedChild(0);
    const ternary = return_stmt.namedChild(0);
    try std.testing.expectEqualStrings("ternary_expression", ternary.getType());
    try std.testing.expectEqualStrings("binary_expression", ternary.childByFieldName("condition").getType());
    try std.testing.expectEqualStrings("meta_property", ternary.childByFieldName("condition").childByFieldName("left").getType());
}

test "extracts long arrow closure before the containing statement" {
    const allocator = std.testing.allocator;
    const source =
        \\runTask((payload: TaskPayload) => {
        \\  console.log(payload.id);
        \\  return payload.title + payload.subtitle;
        \\});
        \\
    ;
    const expected =
        \\function extractedClosure1(payload: TaskPayload) {
        \\  console.log(payload.id);
        \\  return payload.title + payload.subtitle;
        \\}
        \\runTask(extractedClosure1);
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.closure, p.kind);
    try std.testing.expectEqualStrings("long-closure", p.rule);
    try std.testing.expectEqual(proposal.Confidence.medium, p.confidence);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(p.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 2), p.edits.len);
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 9), p.col);
    try std.testing.expect(std.mem.indexOf(u8, p.message, "extractedClosure1") != null);

    const output = try applyProposal(allocator, source, p);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "expression body closure becomes a return statement" {
    const allocator = std.testing.allocator;
    const source =
        \\const labels = items.map((item: Item) => item.name + item.category + item.subcategory + item.extra + item.description);
        \\
    ;
    const expected =
        \\function extractedClosure1(item: Item) { return item.name + item.category + item.subcategory + item.extra + item.description; }
        \\const labels = items.map(extractedClosure1);
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "closure with this stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\register((event: Event) => { return this.handler + event.type + "padding padding padding padding"; });
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expectEqual(@as(usize, 0), proposals[0].edits.len);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "closure extraction skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "this") != null);
}

test "async closure stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\run(async (value: number) => { await work(value); return value + 100000000000000000; });
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "async") != null);
}

test "closure using arguments stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\wrap(function (value: number) { return arguments.length + value + 100000000000000000; });
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "arguments") != null);
}

test "closure using super stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\class Widget extends Base {
        \\  render(): void {
        \\    this.items.forEach((item: Item) => { return super.compute(item) + item.label + item.description + item.subcategory; });
        \\  }
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "super") != null);
}

test "closure using new.target stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\function build(): number {
        \\  return wrap((value: number) => { return new.target === undefined ? value : 100000000000000000; });
        \\}
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "new.target") != null);
}

test "closure using yield stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\wrap((value: number) => { yield value; return value + 100000000000000000000000000000; });
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(!proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "yield") != null);
}

test "short closure yields no proposal" {
    const allocator = std.testing.allocator;
    const source =
        \\items.forEach((item: Item) => { return item.value; });
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "closure outside argument position yields no proposal" {
    const allocator = std.testing.allocator;
    const source =
        \\const handler = (value: number) => { return value + 1000000000000000000000000000000; };
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "insertion point follows the containing statement indentation" {
    const allocator = std.testing.allocator;
    const source =
        \\function process(items: Item[]): void {
        \\  items.forEach((item: Item) => { const label = item.name + item.category + item.subcategory + item.extra; console.log(label); });
        \\}
        \\
    ;
    const expected =
        \\function process(items: Item[]): void {
        \\  function extractedClosure1(item: Item) { const label = item.name + item.category + item.subcategory + item.extra; console.log(label); }
        \\  items.forEach(extractedClosure1);
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);
    try std.testing.expectEqual(@as(u32, 2), proposals[0].line);
    try std.testing.expectEqual(@as(u32, 17), proposals[0].col);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "closure name collision appends counter" {
    const allocator = std.testing.allocator;
    const source =
        \\function extractedClosure1(value: number): number { return value; }
        \\
        \\run((value: number) => { return value + 10000000000000000000000000000000000000000000; });
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "extractedClosure2") != null);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "function extractedClosure2(value: number)") != null);
}

test "tsx arrow closure in argument position is extracted" {
    const allocator = std.testing.allocator;
    const source =
        \\const rows = items.map((item: Item) => <Row value={item.name} extra={item.category} note={item.subcategory} />);
        \\
    ;
    const expected =
        \\function extractedClosure1(item: Item) { return <Row value={item.name} extra={item.category} note={item.subcategory} />; }
        \\const rows = items.map(extractedClosure1);
        \\
    ;

    const proposals = try collectForTest(allocator, source, .tsx);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "collectProposals wires predicate and closure proposals with hashes" {
    const propose = @import("propose.zig");
    const allocator = std.testing.allocator;
    const source =
        \\function isReadyFor(user: User): boolean {
        \\  if (user.isActive && user.hasPaid) {
        \\    return true;
        \\  }
        \\  return false;
        \\}
        \\
        \\runTask((payload: TaskPayload) => {
        \\  console.log(payload.id);
        \\  return payload.title + payload.subtitle;
        \\});
        \\
    ;

    var result = try propose.collectProposals(allocator, source, .typescript, .{});
    defer propose.deinitCollectResult(allocator, &result);

    try std.testing.expect(!result.parse_error);
    try std.testing.expectEqual(@as(usize, 2), result.proposals.len);
    try std.testing.expectEqual(proposal.ProposalKind.predicate, result.proposals[0].kind);
    try std.testing.expectEqual(proposal.ProposalKind.closure, result.proposals[1].kind);
    for (result.proposals) |p| {
        try std.testing.expectEqual(@as(usize, 64), p.expected_hash.len);
    }
}

test "probe python closure node types" {
    const source =
        \\entries = sorted(entries, key=lambda entry: entry.name + entry.category)
        \\
        \\process(items, lambda a, b: a + b, "name")
    ;
    const py_lang = grammars.Language.python.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    defer bindings.deinitThreadParser();
    try std.testing.expect(parser.setLanguage(py_lang));

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const call = tree.rootNode().namedChild(0).namedChild(1);
    try std.testing.expectEqualStrings("call", call.getType());
    const args = call.childByFieldName("arguments");
    try std.testing.expectEqualStrings("argument_list", args.getType());

    const keyword = args.namedChild(1);
    try std.testing.expectEqualStrings("keyword_argument", keyword.getType());
    try std.testing.expectEqualStrings("key", keyword.childByFieldName("name").slice(source));
    const lambda = keyword.childByFieldName("value");
    try std.testing.expectEqualStrings("lambda", lambda.getType());
    try std.testing.expectEqualStrings("lambda_parameters", lambda.childByFieldName("parameters").getType());
    try std.testing.expectEqualStrings("entry", lambda.childByFieldName("parameters").slice(source));
    try std.testing.expectEqualStrings("entry.name + entry.category", lambda.childByFieldName("body").slice(source));

    const call2 = tree.rootNode().namedChild(1);
    const second_lambda = call2.childByFieldName("arguments").namedChild(1);
    try std.testing.expectEqualStrings("lambda", second_lambda.getType());
    try std.testing.expectEqualStrings("a, b", second_lambda.childByFieldName("parameters").slice(source));
}

test "extracts long python lambda before the containing statement" {
    const allocator = std.testing.allocator;
    const source =
        \\entries = sorted(entries, key=lambda entry: entry.name + entry.category + entry.subcategory + entry.extra + entry.description)
        \\
    ;
    const expected =
        \\def extracted_closure1(entry):
        \\    return entry.name + entry.category + entry.subcategory + entry.extra + entry.description
        \\entries = sorted(entries, key=extracted_closure1)
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.closure, p.kind);
    try std.testing.expectEqualStrings("long-closure", p.rule);
    try std.testing.expectEqual(proposal.Confidence.medium, p.confidence);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(p.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 2), p.edits.len);
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expect(std.mem.indexOf(u8, p.message, "extracted_closure1") != null);

    const output = try applyProposal(allocator, source, p);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "python lambda keeps nested indentation" {
    const allocator = std.testing.allocator;
    const source =
        \\def build(entries):
        \\    return sorted(entries, key=lambda entry: entry.name + entry.category + entry.subcategory + entry.extra + entry.description)
        \\
    ;
    const expected =
        \\def build(entries):
        \\    def extracted_closure1(entry):
        \\        return entry.name + entry.category + entry.subcategory + entry.extra + entry.description
        \\    return sorted(entries, key=extracted_closure1)
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

test "python lambda assigned to a variable yields no proposal" {
    const allocator = std.testing.allocator;
    const source =
        \\handler = lambda entry: entry.name + entry.category + entry.subcategory + entry.extra + entry.description
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "python short lambda yields no proposal" {
    const allocator = std.testing.allocator;
    const source =
        \\entries = sorted(entries, key=lambda entry: entry.name)
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "python closure name collision appends counter" {
    const allocator = std.testing.allocator;
    const source =
        \\def extracted_closure1(entry):
        \\    return entry
        \\
        \\entries = sorted(entries, key=lambda entry: entry.name + entry.category + entry.subcategory + entry.extra + entry.description)
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expect(proposals[0].safe_to_apply);
    try std.testing.expect(std.mem.indexOf(u8, proposals[0].message, "extracted_closure2") != null);

    const output = try applyProposal(allocator, source, proposals[0]);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "def extracted_closure2(entry):") != null);
}
