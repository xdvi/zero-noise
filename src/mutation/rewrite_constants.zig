const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");
const proposal = @import("proposal.zig");
const edits = @import("edits.zig");

pub fn supportedLanguages() []const grammars.Language {
    return &.{ .typescript, .tsx, .python, .go, .zig, .rust, .c_sharp };
}

const LiteralKind = enum { string, number, boolean };

const LiteralSyntax = struct {
    string_types: []const []const u8,
    number_types: []const []const u8,
    boolean_types: []const []const u8,
};

fn literalSyntax(lang: grammars.Language) ?LiteralSyntax {
    return switch (lang) {
        .typescript, .tsx => .{
            .string_types = &.{ "string", "template_string" },
            .number_types = &.{"number"},
            .boolean_types = &.{},
        },
        .python => .{
            .string_types = &.{"string"},
            .number_types = &.{"integer"},
            .boolean_types = &.{},
        },
        .go => .{
            .string_types = &.{ "interpreted_string_literal", "raw_string_literal" },
            .number_types = &.{ "int_literal", "float_literal" },
            .boolean_types = &.{},
        },
        .zig => .{
            .string_types = &.{"string"},
            .number_types = &.{"integer"},
            .boolean_types = &.{},
        },
        .rust => .{
            .string_types = &.{"string_literal"},
            .number_types = &.{ "integer_literal", "float_literal" },
            .boolean_types = &.{},
        },
        .c_sharp => .{
            .string_types = &.{ "string_literal", "verbatim_string_literal" },
            .number_types = &.{"integer_literal"},
            .boolean_types = &.{"boolean_literal"},
        },
        else => null,
    };
}

const import_export_types = [_][]const u8{
    "import_statement",
    "import_declaration",
    "import_from_statement",
    "future_import_statement",
    "import_spec",
    "import_clause",
    "export_statement",
    "use_declaration",
    "using_directive",
    "package_clause",
    "package_declaration",
    "extern_crate_declaration",
};

const annotation_types = [_][]const u8{
    "decorator",
    "attribute",
    "attribute_item",
    "inner_attribute_item",
    "attribute_list",
    "attribute_argument",
    "global_attribute",
    "annotation",
    "meta_item",
    "meta_name_value",
};

const case_pattern_types = [_][]const u8{
    "switch_case",
    "switch_default",
    "switch_section",
    "switch_label",
    "switch_expression_arm",
    "case_switch_label",
    "case_pattern_switch_label",
    "case_clause",
    "case_pattern",
    "expression_case",
    "type_case",
    "communication_case",
    "default_case",
    "match_arm",
    "match_pattern",
    "switch_prong",
};

const Occurrence = struct {
    node: bindings.TSNode,
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

const LiteralEntry = struct {
    kind: LiteralKind,
    occurrences: std.ArrayList(Occurrence),
};

const Candidate = struct {
    key: []const u8,
    entry: *LiteralEntry,
};

const Collector = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    syntax: LiteralSyntax,
    literals: *std.StringHashMap(LiteralEntry),
    identifiers: *std.StringHashMap(void),
};

/// Extracts repeated literals (>= 3 eligible occurrences) into named constants.
/// One proposal per literal; each language anchors the declaration after its
/// last import-like declaration, falling back to file start (Python: after the
/// module docstring when present; Go: after the package clause).
pub fn collect(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    const syntax = literalSyntax(lang) orelse return &.{};

    var identifiers = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = identifiers.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        identifiers.deinit();
    }

    var literals = std.StringHashMap(LiteralEntry).init(allocator);
    defer {
        var entry_it = literals.iterator();
        while (entry_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.occurrences.deinit(allocator);
        }
        literals.deinit();
    }

    var collector = Collector{
        .allocator = allocator,
        .source = source,
        .lang = lang,
        .syntax = syntax,
        .literals = &literals,
        .identifiers = &identifiers,
    };
    try walkCollect(&collector, root);

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);

    var entry_it = literals.iterator();
    while (entry_it.next()) |entry| {
        if (entry.value_ptr.occurrences.items.len < 3) continue;
        try candidates.append(allocator, .{
            .key = entry.key_ptr.*,
            .entry = entry.value_ptr,
        });
    }
    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);

    var proposals: std.ArrayList(proposal.Proposal) = .empty;
    errdefer {
        for (proposals.items) |p| p.deinit(allocator);
        proposals.deinit(allocator);
    }

    var used_names = std.StringHashMap(void).init(allocator);
    defer {
        var name_it = used_names.keyIterator();
        while (name_it.next()) |key| allocator.free(key.*);
        used_names.deinit();
    }

    const file_anchor = fileInsertionOffset(lang, root, source);
    for (candidates.items) |candidate| {
        try proposals.append(allocator, try buildProposal(
            allocator,
            lang,
            candidate,
            source,
            file_anchor,
            &identifiers,
            &used_names,
        ));
    }

    return proposals.toOwnedSlice(allocator);
}

fn walkCollect(collector: *Collector, node: bindings.TSNode) !void {
    if (node.isNull()) return;

    const node_type = node.getType();

    if (isIdentifierNodeType(node_type)) {
        const slice = node.slice(collector.source);
        if (slice.len > 0 and !collector.identifiers.contains(slice)) {
            const owned = try collector.allocator.dupe(u8, slice);
            errdefer collector.allocator.free(owned);
            try collector.identifiers.put(owned, {});
        }
    }

    if (kindFor(collector.syntax, node_type)) |kind| {
        if (!isInterpolatedString(node, node_type) and
            !isExcludedOccurrence(node, collector.source, collector.lang))
        {
            try recordLiteral(collector, node, kind);
        }
    }

    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        try walkCollect(collector, node.namedChild(i));
    }
}

fn recordLiteral(collector: *Collector, node: bindings.TSNode, kind: LiteralKind) !void {
    const key = node.slice(collector.source);
    if (key.len == 0) return;

    const gop = try collector.literals.getOrPut(key);
    if (!gop.found_existing) {
        gop.key_ptr.* = try collector.allocator.dupe(u8, key);
        gop.value_ptr.* = .{ .kind = kind, .occurrences = .empty };
    }

    const point = node.startPoint();
    try gop.value_ptr.occurrences.append(collector.allocator, .{
        .node = node,
        .start = node.startByte(),
        .end = node.endByte(),
        .line = point.row + 1,
        .col = point.column + 1,
    });
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    const a_start = a.entry.occurrences.items[0].start;
    const b_start = b.entry.occurrences.items[0].start;
    if (a_start != b_start) return a_start < b_start;
    return std.mem.lessThan(u8, a.key, b.key);
}

fn buildProposal(
    allocator: std.mem.Allocator,
    lang: grammars.Language,
    candidate: Candidate,
    source: []const u8,
    file_anchor: ?u32,
    identifiers: *const std.StringHashMap(void),
    used_names: *std.StringHashMap(void),
) !proposal.Proposal {
    const entry = candidate.entry;
    const count: u32 = @intCast(entry.occurrences.items.len);
    const first = entry.occurrences.items[0];

    var anchor: ?u32 = file_anchor;
    var indent: []const u8 = "";

    if (!canExtract(lang, entry.kind)) {
        const message = try std.fmt.allocPrint(
            allocator,
            "literal '{s}' repeated {d} times; extraction for this literal type is not supported for {s} (advisory)",
            .{ candidate.key, count, @tagName(lang) },
        );
        return advisoryProposal(allocator, first, message);
    }

    if (lang == .c_sharp) {
        if (csharpClassBodyOffset(entry.occurrences.items)) |class_offset| {
            anchor = class_offset;
            indent = "    ";
        } else {
            const message = try std.fmt.allocPrint(
                allocator,
                "literal '{s}' repeated {d} times; occurrences span multiple classes (advisory)",
                .{ candidate.key, count },
            );
            return advisoryProposal(allocator, first, message);
        }
    }

    const name = try uniqueName(allocator, candidate.key, entry.kind, identifiers, used_names);
    defer allocator.free(name);
    try used_names.put(try allocator.dupe(u8, name), {});

    const declaration = try renderDeclaration(allocator, lang, entry.kind, name, candidate.key);
    defer allocator.free(declaration);
    const insertion_text = try buildInsertionText(allocator, declaration, source, anchor, indent);
    errdefer allocator.free(insertion_text);

    const owned_edits = try allocator.alloc(edits.Edit, entry.occurrences.items.len + 1);
    errdefer allocator.free(owned_edits);
    for (owned_edits) |*edit| edit.* = .{ .start = 0, .end = 0, .replacement = "" };

    const insertion_offset: u32 = anchor orelse 0;
    owned_edits[0] = .{
        .start = insertion_offset,
        .end = insertion_offset,
        .replacement = insertion_text,
    };

    var built: usize = 1;
    errdefer for (owned_edits[1..built]) |edit| allocator.free(edit.replacement);
    while (built < owned_edits.len) : (built += 1) {
        const occurrence = entry.occurrences.items[built - 1];
        owned_edits[built] = .{
            .start = occurrence.start,
            .end = occurrence.end,
            .replacement = try allocator.dupe(u8, name),
        };
    }
    edits.sortEdits(owned_edits);

    const message = try std.fmt.allocPrint(
        allocator,
        "literal '{s}' repeated {d} times; extract to a named constant",
        .{ candidate.key, count },
    );
    errdefer allocator.free(message);
    const rule = try allocator.dupe(u8, "repeated-literal");
    errdefer allocator.free(rule);

    return .{
        .kind = .constant,
        .rule = rule,
        .file = "",
        .line = first.line,
        .col = first.col,
        .message = message,
        .confidence = .high,
        .naming_required = true,
        .safe_to_apply = true,
        .edits = owned_edits,
        .expected_hash = "",
    };
}

fn advisoryProposal(
    allocator: std.mem.Allocator,
    first: Occurrence,
    message: []const u8,
) !proposal.Proposal {
    errdefer allocator.free(message);
    const rule = try allocator.dupe(u8, "repeated-literal");
    errdefer allocator.free(rule);
    return .{
        .kind = .constant,
        .rule = rule,
        .file = "",
        .line = first.line,
        .col = first.col,
        .message = message,
        .confidence = .medium,
        .naming_required = true,
        .safe_to_apply = false,
        .edits = &.{},
        .expected_hash = "",
    };
}

/// TS/TSX extract strings, template strings without substitutions, and
/// numbers; Python extracts strings and integers; Go and Zig extract
/// strings and numbers (bool literals are not collected); Rust extracts
/// strings only; C# extracts strings, integers, and bools.
fn canExtract(lang: grammars.Language, kind: LiteralKind) bool {
    return switch (lang) {
        .typescript, .tsx => kind == .string or kind == .number,
        .python => kind == .string or kind == .number,
        .go => kind == .string or kind == .number,
        .zig => kind == .string or kind == .number,
        .rust => kind == .string,
        .c_sharp => true,
        else => false,
    };
}

fn renderDeclaration(
    allocator: std.mem.Allocator,
    lang: grammars.Language,
    kind: LiteralKind,
    name: []const u8,
    literal: []const u8,
) ![]u8 {
    return switch (lang) {
        .typescript, .tsx => std.fmt.allocPrint(allocator, "const {s} = {s};", .{ name, literal }),
        .python => std.fmt.allocPrint(allocator, "{s} = {s}", .{ name, literal }),
        .go => std.fmt.allocPrint(allocator, "const {s} = {s}", .{ name, literal }),
        .zig => std.fmt.allocPrint(allocator, "const {s} = {s};", .{ name, literal }),
        .rust => std.fmt.allocPrint(allocator, "const {s}: &str = {s};", .{ name, literal }),
        .c_sharp => switch (kind) {
            .string => std.fmt.allocPrint(allocator, "const string {s} = {s};", .{ name, literal }),
            .number => std.fmt.allocPrint(allocator, "const int {s} = {s};", .{ name, literal }),
            .boolean => std.fmt.allocPrint(allocator, "const bool {s} = {s};", .{ name, literal }),
        },
        else => unreachable,
    };
}

fn buildInsertionText(
    allocator: std.mem.Allocator,
    declaration: []const u8,
    source: []const u8,
    anchor: ?u32,
    indent: []const u8,
) ![]u8 {
    if (anchor) |offset| {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ newlineAt(source, offset), indent, declaration });
    }
    return std.fmt.allocPrint(allocator, "{s}\n", .{declaration});
}

fn newlineAt(source: []const u8, offset: usize) []const u8 {
    if (offset < source.len and source[offset] == '\r') return "\r\n";
    return "\n";
}

/// Byte offset after which a new top-level declaration is inserted.
/// `null` means file start.
fn fileInsertionOffset(lang: grammars.Language, root: bindings.TSNode, source: []const u8) ?u32 {
    var last_import: ?u32 = null;

    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const child = root.namedChild(i);
        const child_type = child.getType();
        const is_import = switch (lang) {
            .typescript, .tsx => std.mem.eql(u8, child_type, "import_statement"),
            .python => std.mem.eql(u8, child_type, "import_statement") or
                std.mem.eql(u8, child_type, "import_from_statement") or
                std.mem.eql(u8, child_type, "future_import_statement"),
            .go => std.mem.eql(u8, child_type, "import_declaration"),
            .zig => isZigImportDeclaration(child, source),
            .rust => std.mem.eql(u8, child_type, "use_declaration"),
            else => false,
        };
        if (is_import) {
            last_import = if (last_import) |current| @max(current, child.endByte()) else child.endByte();
        }
    }

    if (last_import) |offset| return offset;

    switch (lang) {
        .python => return pythonModuleDocstringEnd(root),
        // Go requires the package clause before any other declaration.
        .go => return firstTopLevelChildEnd(root, "package_clause"),
        else => return null,
    }
}

fn firstTopLevelChildEnd(root: bindings.TSNode, node_type: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const child = root.namedChild(i);
        if (std.mem.eql(u8, child.getType(), node_type)) return child.endByte();
    }
    return null;
}

fn isZigImportDeclaration(child: bindings.TSNode, source: []const u8) bool {
    if (!std.mem.eql(u8, child.getType(), "variable_declaration")) return false;
    var i: u32 = 0;
    while (i < child.namedChildCount()) : (i += 1) {
        const sub = child.namedChild(i);
        if (std.mem.eql(u8, sub.getType(), "builtin_function") and
            std.mem.startsWith(u8, sub.slice(source), "@import"))
        {
            return true;
        }
    }
    return false;
}

/// Offset just inside the `{` of the single class body containing every
/// occurrence; `null` when occurrences span classes or sit outside one.
fn csharpClassBodyOffset(occurrences: []const Occurrence) ?u32 {
    const first_class = enclosingClass(occurrences[0].node) orelse return null;
    for (occurrences[1..]) |occurrence| {
        const class = enclosingClass(occurrence.node) orelse return null;
        if (!sameNode(class, first_class)) return null;
    }
    const body = classBodyNode(first_class) orelse return null;
    return body.startByte() + 1;
}

fn enclosingClass(node: bindings.TSNode) ?bindings.TSNode {
    var current = node.parent();
    while (!current.isNull()) {
        const node_type = current.getType();
        if (std.mem.eql(u8, node_type, "class_declaration")) return current;
        if (std.mem.eql(u8, node_type, "struct_declaration") or
            std.mem.eql(u8, node_type, "record_declaration") or
            std.mem.eql(u8, node_type, "interface_declaration"))
        {
            return null;
        }
        current = current.parent();
    }
    return null;
}

fn classBodyNode(class_node: bindings.TSNode) ?bindings.TSNode {
    var i: u32 = 0;
    while (i < class_node.namedChildCount()) : (i += 1) {
        const child = class_node.namedChild(i);
        if (std.mem.eql(u8, child.getType(), "declaration_list")) return child;
    }
    return null;
}

fn pythonModuleDocstringEnd(root: bindings.TSNode) ?u32 {
    if (root.namedChildCount() == 0) return null;
    const first = root.namedChild(0);
    if (std.mem.eql(u8, first.getType(), "string")) return first.endByte();
    if (std.mem.eql(u8, first.getType(), "expression_statement") and
        first.namedChildCount() == 1 and
        std.mem.eql(u8, first.namedChild(0).getType(), "string"))
    {
        return first.endByte();
    }
    return null;
}

fn uniqueName(
    allocator: std.mem.Allocator,
    literal: []const u8,
    kind: LiteralKind,
    identifiers: *const std.StringHashMap(void),
    used_names: *const std.StringHashMap(void),
) ![]u8 {
    const base = try sanitizeName(allocator, literal, kind);
    defer allocator.free(base);

    if (!identifiers.contains(base) and !used_names.contains(base)) {
        return allocator.dupe(u8, base);
    }

    var suffix: u32 = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, suffix });
        if (!identifiers.contains(candidate) and !used_names.contains(candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
}

fn sanitizeName(allocator: std.mem.Allocator, literal: []const u8, kind: LiteralKind) ![]u8 {
    const content = if (kind == .string) stringContent(literal) else literal;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var pending_separator = false;
    for (content) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (pending_separator and buf.items.len > 0) try buf.append(allocator, '_');
            pending_separator = false;
            try buf.append(allocator, std.ascii.toUpper(ch));
        } else {
            pending_separator = true;
        }
    }

    if (buf.items.len == 0 or std.ascii.isDigit(buf.items[0])) {
        try buf.insertSlice(allocator, 0, "L_");
    }
    if (buf.items.len > 40) buf.items.len = 40;
    return buf.toOwnedSlice(allocator);
}

/// Strips string delimiters (including raw/verbatim prefixes and triple
/// quotes) so names derive from the content, not the syntax.
fn stringContent(literal: []const u8) []const u8 {
    if (literal.len < 2) return literal;

    if (literal[0] == '`' and literal[literal.len - 1] == '`') {
        return literal[1 .. literal.len - 1];
    }

    var open: usize = 0;
    while (open < literal.len and literal[open] != '"' and literal[open] != '\'') : (open += 1) {}
    if (open >= literal.len) return literal;
    const quote = literal[open];

    var open_len: usize = 0;
    while (open + open_len < literal.len and literal[open + open_len] == quote) : (open_len += 1) {}

    var hashes: usize = 0;
    while (hashes < literal.len and literal[literal.len - 1 - hashes] == '#') : (hashes += 1) {}

    var end = literal.len - hashes;
    var close_len: usize = 0;
    while (end > open + open_len and literal[end - 1] == quote) : (end -= 1) {
        close_len += 1;
    }
    if (close_len == 0 or end < open + open_len) return literal;

    return literal[open + open_len .. end];
}

fn kindFor(syntax: LiteralSyntax, node_type: []const u8) ?LiteralKind {
    if (containsType(syntax.string_types, node_type)) return .string;
    if (containsType(syntax.number_types, node_type)) return .number;
    if (containsType(syntax.boolean_types, node_type)) return .boolean;
    return null;
}

fn containsType(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn isIdentifierNodeType(node_type: []const u8) bool {
    return std.mem.indexOf(u8, node_type, "identifier") != null;
}

fn isInterpolatedString(node: bindings.TSNode, node_type: []const u8) bool {
    if (!std.mem.eql(u8, node_type, "template_string") and !std.mem.eql(u8, node_type, "string")) {
        return false;
    }
    return hasChildType(node, "template_substitution") or
        hasChildType(node, "interpolation") or
        hasChildType(node, "string_interpolation");
}

fn hasChildType(node: bindings.TSNode, node_type: []const u8) bool {
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        if (std.mem.eql(u8, node.child(i).getType(), node_type)) return true;
    }
    return false;
}

const unsafe_context_types = [_][]const u8{
    // Rust macro arguments must stay literals (`println!`, `include_str!`).
    "token_tree",
    // JSX attribute values need `{expr}` braces; a bare identifier is invalid JSX.
    "jsx_attribute",
};

fn isExcludedOccurrence(node: bindings.TSNode, source: []const u8, lang: grammars.Language) bool {
    // A tagged template's `template_string` is syntax (`tag\`...\``), not a value.
    if (std.mem.eql(u8, node.getType(), "template_string")) {
        const parent = node.parent();
        if (!parent.isNull() and std.mem.eql(u8, parent.getType(), "call_expression")) return true;
    }

    var current = node.parent();
    while (!current.isNull()) {
        const node_type = current.getType();
        if (containsType(&import_export_types, node_type)) return true;
        if (containsType(&annotation_types, node_type)) return true;
        if (containsType(&case_pattern_types, node_type)) return true;
        if (containsType(&unsafe_context_types, node_type)) return true;
        if (std.mem.eql(u8, node_type, "builtin_function") and
            std.mem.startsWith(u8, current.slice(source), "@import"))
        {
            return true;
        }
        current = current.parent();
    }

    if (lang == .python and isPythonDocstring(node)) return true;
    return false;
}

/// The first statement of a module/class/function body is its docstring.
/// tree-sitter-python attaches the literal directly to the body; the
/// `expression_statement` wrapper is kept as a fallback.
fn isPythonDocstring(node: bindings.TSNode) bool {
    const parent = node.parent();
    if (parent.isNull()) return false;
    const parent_type = parent.getType();

    if (std.mem.eql(u8, parent_type, "module")) {
        return sameNode(parent.namedChild(0), node);
    }

    if (std.mem.eql(u8, parent_type, "block")) {
        const owner = parent.parent();
        if (owner.isNull()) return false;
        const owner_type = owner.getType();
        if (!std.mem.eql(u8, owner_type, "function_definition") and
            !std.mem.eql(u8, owner_type, "class_definition"))
        {
            return false;
        }
        return sameNode(parent.namedChild(0), node);
    }

    if (!std.mem.eql(u8, parent_type, "expression_statement")) return false;
    if (parent.namedChildCount() != 1) return false;

    const container = parent.parent();
    if (container.isNull()) return false;
    const container_type = container.getType();

    if (std.mem.eql(u8, container_type, "module")) {
        return sameNode(container.namedChild(0), parent);
    }
    if (std.mem.eql(u8, container_type, "block")) {
        const owner = container.parent();
        if (owner.isNull()) return false;
        const owner_type = owner.getType();
        if (!std.mem.eql(u8, owner_type, "function_definition") and
            !std.mem.eql(u8, owner_type, "class_definition"))
        {
            return false;
        }
        return sameNode(container.namedChild(0), parent);
    }
    return false;
}

fn sameNode(a: bindings.TSNode, b: bindings.TSNode) bool {
    return a.startByte() == b.startByte() and a.endByte() == b.endByte();
}

fn collectForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) ![]proposal.Proposal {
    const ts_lang = lang.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    try std.testing.expect(parser.setLanguage(ts_lang));
    var tree = try parser.parseString(source);
    defer tree.deinit();
    return collect(allocator, source, lang, tree.rootNode());
}

fn deinitProposals(allocator: std.mem.Allocator, proposals: []proposal.Proposal) void {
    for (proposals) |p| p.deinit(allocator);
    allocator.free(proposals);
}

fn candidateFor(allocator: std.mem.Allocator, source: []const u8, p: proposal.Proposal) ![]u8 {
    const copy = try allocator.dupe(edits.Edit, p.edits);
    defer allocator.free(copy);
    edits.sortEdits(copy);
    return edits.apply(allocator, source, copy);
}

fn hasNodeTypeAnywhere(node: bindings.TSNode, node_type: []const u8) bool {
    if (node.isNull()) return false;
    if (std.mem.eql(u8, node.getType(), node_type)) return true;
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        if (hasNodeTypeAnywhere(node.namedChild(i), node_type)) return true;
    }
    return false;
}

fn probeParse(source: []const u8, lang: grammars.Language) !bindings.Tree {
    const ts_lang = lang.getTsLanguage().?;
    var parser = try bindings.getThreadParser();
    try std.testing.expect(parser.setLanguage(ts_lang));
    return parser.parseString(source);
}

test "probe literal node types per grammar" {
    const cases = [_]struct {
        lang: grammars.Language,
        source: []const u8,
        expected: []const []const u8,
    }{
        .{ .lang = .typescript, .source = "const a = \"x\"; const b = `y`; const c = 1;", .expected = &.{ "string", "template_string", "number" } },
        .{ .lang = .python, .source = "x = \"a\"\ny = 1", .expected = &.{ "string", "integer" } },
        .{ .lang = .go, .source = "package main\nvar a = \"x\"\nvar b = `y`\nvar c = 1\nvar d = 1.5", .expected = &.{ "interpreted_string_literal", "raw_string_literal", "int_literal", "float_literal" } },
        .{ .lang = .zig, .source = "const a = \"x\";\nconst b = 1;", .expected = &.{ "string", "integer" } },
        .{ .lang = .rust, .source = "fn f() { let a = \"x\"; let b = 1; let c = 1.5; }", .expected = &.{ "string_literal", "integer_literal", "float_literal" } },
        .{ .lang = .c_sharp, .source = "class C { string a = \"x\"; int b = 1; bool c = true; }", .expected = &.{ "string_literal", "integer_literal", "boolean_literal" } },
    };

    for (cases) |case| {
        var tree = try probeParse(case.source, case.lang);
        defer tree.deinit();
        for (case.expected) |node_type| {
            try std.testing.expect(hasNodeTypeAnywhere(tree.rootNode(), node_type));
        }
    }
}

test "extracts literal repeated three times in TypeScript" {
    const allocator = std.testing.allocator;
    const source =
        \\import { user } from "./user";
        \\
        \\const a = "ACTIVE";
        \\const b = "ACTIVE";
        \\const c = "ACTIVE";
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.constant, p.kind);
    try std.testing.expectEqualStrings("repeated-literal", p.rule);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(p.safe_to_apply);
    try std.testing.expectEqual(proposal.Confidence.high, p.confidence);
    try std.testing.expectEqual(@as(u32, 3), p.line);
    try std.testing.expectEqual(@as(u32, 11), p.col);
    try std.testing.expectEqual(@as(usize, 4), p.edits.len);

    const candidate = try candidateFor(allocator, source, p);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "import { user } from \"./user\";\n" ++
            "const ACTIVE = \"ACTIVE\";\n" ++
            "\n" ++
            "const a = ACTIVE;\n" ++
            "const b = ACTIVE;\n" ++
            "const c = ACTIVE;\n",
        candidate,
    );
}

test "two occurrences stay untouched" {
    const allocator = std.testing.allocator;
    const source =
        \\const a = "ACTIVE";
        \\const b = "ACTIVE";
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "literal in import path is excluded" {
    const allocator = std.testing.allocator;
    const source =
        \\import { a } from "./shared";
        \\import { b } from "./shared";
        \\import { c } from "./shared";
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "name collision appends suffix" {
    const allocator = std.testing.allocator;
    const source =
        \\const ACTIVE = 1;
        \\const a = "ACTIVE";
        \\const b = "ACTIVE";
        \\const c = "ACTIVE";
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expect(std.mem.startsWith(u8, candidate, "const ACTIVE_2 = \"ACTIVE\";\n"));
    try std.testing.expect(std.mem.endsWith(u8, candidate, "const c = ACTIVE_2;\n"));

    const second_source =
        \\const ACTIVE = 1;
        \\const ACTIVE_2 = 2;
        \\const a = "ACTIVE";
        \\const b = "ACTIVE";
        \\const c = "ACTIVE";
        \\
    ;
    const second = try collectForTest(allocator, second_source, .typescript);
    defer deinitProposals(allocator, second);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    const second_candidate = try candidateFor(allocator, second_source, second[0]);
    defer allocator.free(second_candidate);
    try std.testing.expect(std.mem.startsWith(u8, second_candidate, "const ACTIVE_3 = \"ACTIVE\";\n"));
}

test "go declaration inserted after last import" {
    const allocator = std.testing.allocator;
    const source =
        \\package main
        \\
        \\import "fmt"
        \\
        \\func main() {
        \\    fmt.Println("hello")
        \\    fmt.Println("hello")
        \\    fmt.Println("hello")
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .go);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "package main\n" ++
            "\n" ++
            "import \"fmt\"\n" ++
            "const HELLO = \"hello\"\n" ++
            "\n" ++
            "func main() {\n" ++
            "    fmt.Println(HELLO)\n" ++
            "    fmt.Println(HELLO)\n" ++
            "    fmt.Println(HELLO)\n" ++
            "}\n",
        candidate,
    );
}

test "go import block anchor and raw strings" {
    const allocator = std.testing.allocator;
    const source =
        \\package main
        \\
        \\import (
        \\    "fmt"
        \\    "os"
        \\)
        \\
        \\func main() {
        \\    fmt.Println(`raw`)
        \\    fmt.Println(`raw`)
        \\    fmt.Println(`raw`)
        \\    _ = os.Args
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .go);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expect(std.mem.indexOf(u8, candidate, ")\nconst RAW = `raw`\n") != null);
}

test "go bool literals stay untouched" {
    const allocator = std.testing.allocator;
    const source =
        \\package main
        \\
        \\func f() {
        \\    a := true
        \\    b := true
        \\    c := true
        \\    _ = a
        \\    _ = b
        \\    _ = c
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .go);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "go without imports inserts after the package clause" {
    const allocator = std.testing.allocator;
    const source =
        \\package main
        \\
        \\var a = 42
        \\var b = 42
        \\var c = 42
        \\
    ;

    const proposals = try collectForTest(allocator, source, .go);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "package main\n" ++
            "const L_42 = 42\n" ++
            "\n" ++
            "var a = L_42\n" ++
            "var b = L_42\n" ++
            "var c = L_42\n",
        candidate,
    );
}

test "zig declaration inserted after @import declaration" {
    const allocator = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    const a = "hello";
        \\    const b = "hello";
        \\    const c = "hello";
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .zig);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n" ++
            "const HELLO = \"hello\";\n" ++
            "\n" ++
            "pub fn main() void {\n" ++
            "    const a = HELLO;\n" ++
            "    const b = HELLO;\n" ++
            "    const c = HELLO;\n" ++
            "    _ = a;\n" ++
            "    _ = b;\n" ++
            "    _ = c;\n" ++
            "}\n",
        candidate,
    );
}

test "zig @import path occurrences are excluded" {
    const allocator = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\
        \\const a = "std";
        \\const b = "std";
        \\const c = "std";
        \\
    ;

    const proposals = try collectForTest(allocator, source, .zig);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    try std.testing.expectEqual(@as(usize, 4), proposals[0].edits.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expect(std.mem.startsWith(u8, candidate, "const std = @import(\"std\");\nconst STD = \"std\";\n"));
    try std.testing.expect(std.mem.endsWith(u8, candidate, "const c = STD;\n"));
}

test "zig bool literals stay untouched and numbers extract" {
    const allocator = std.testing.allocator;
    const bool_source =
        \\pub fn f() void {
        \\    const a = true;
        \\    const b = true;
        \\    const c = true;
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
    ;
    const bool_proposals = try collectForTest(allocator, bool_source, .zig);
    defer deinitProposals(allocator, bool_proposals);
    try std.testing.expectEqual(@as(usize, 0), bool_proposals.len);

    const number_source =
        \\pub fn f() void {
        \\    const a = 42;
        \\    const b = 42;
        \\    const c = 42;
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
    ;
    const number_proposals = try collectForTest(allocator, number_source, .zig);
    defer deinitProposals(allocator, number_proposals);
    try std.testing.expectEqual(@as(usize, 1), number_proposals.len);
    const candidate = try candidateFor(allocator, number_source, number_proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expect(std.mem.startsWith(u8, candidate, "const L_42 = 42;\n"));
}

test "long literal name truncates at 40 chars" {
    const allocator = std.testing.allocator;
    const literal = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const source = try std.fmt.allocPrint(
        allocator,
        "const a = \"{s}\";\nconst b = \"{s}\";\nconst c = \"{s}\";\n",
        .{ literal, literal, literal },
    );
    defer allocator.free(source);

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const insertion = proposals[0].edits[0];
    try std.testing.expectEqual(@as(u32, 0), insertion.start);
    try std.testing.expectEqual(@as(u32, 0), insertion.end);

    const name_start = "const ".len;
    const name_end = std.mem.indexOf(u8, insertion.replacement, " = ").?;
    try std.testing.expectEqual(@as(usize, 40), name_end - name_start);
    try std.testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", insertion.replacement[name_start..name_end]);
}

test "python docstring occurrence excluded" {
    const allocator = std.testing.allocator;

    const module_source =
        \\"dup"
        \\x = "dup"
        \\y = "dup"
        \\
    ;
    const module_proposals = try collectForTest(allocator, module_source, .python);
    defer deinitProposals(allocator, module_proposals);
    try std.testing.expectEqual(@as(usize, 0), module_proposals.len);

    const function_source =
        \\def f():
        \\    "dup"
        \\    x = "dup"
        \\    y = "dup"
        \\
    ;
    const function_proposals = try collectForTest(allocator, function_source, .python);
    defer deinitProposals(allocator, function_proposals);
    try std.testing.expectEqual(@as(usize, 0), function_proposals.len);

    const class_source =
        \\class C:
        \\    "dup"
        \\    x = "dup"
        \\    y = "dup"
        \\
    ;
    const class_proposals = try collectForTest(allocator, class_source, .python);
    defer deinitProposals(allocator, class_proposals);
    try std.testing.expectEqual(@as(usize, 0), class_proposals.len);

    const extraction_source =
        \\"dup"
        \\x = "dup"
        \\y = "dup"
        \\z = "dup"
        \\
    ;
    const extraction_proposals = try collectForTest(allocator, extraction_source, .python);
    defer deinitProposals(allocator, extraction_proposals);
    try std.testing.expectEqual(@as(usize, 1), extraction_proposals.len);
    try std.testing.expectEqual(@as(usize, 4), extraction_proposals[0].edits.len);
}

test "python declaration inserted after imports with no type annotation" {
    const allocator = std.testing.allocator;
    const source =
        \\import os
        \\
        \\a = "ACTIVE"
        \\b = "ACTIVE"
        \\c = "ACTIVE"
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "import os\n" ++
            "ACTIVE = \"ACTIVE\"\n" ++
            "\n" ++
            "a = ACTIVE\n" ++
            "b = ACTIVE\n" ++
            "c = ACTIVE\n",
        candidate,
    );
}

test "rust string declaration inserted after last use" {
    const allocator = std.testing.allocator;
    const source =
        \\use std::fmt;
        \\
        \\fn main() {
        \\    let a = "hello";
        \\    let b = "hello";
        \\    let c = "hello";
        \\    println!("{}{}{}", a, b, c);
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .rust);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "use std::fmt;\n" ++
            "const HELLO: &str = \"hello\";\n" ++
            "\n" ++
            "fn main() {\n" ++
            "    let a = HELLO;\n" ++
            "    let b = HELLO;\n" ++
            "    let c = HELLO;\n" ++
            "    println!(\"{}{}{}\", a, b, c);\n" ++
            "}\n",
        candidate,
    );
}

test "rust int literals stay advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\fn f() {
        \\    let a = 42;
        \\    let b = 42;
        \\    let c = 42;
        \\    let _ = (a, b, c);
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .rust);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.constant, p.kind);
    try std.testing.expectEqualStrings("repeated-literal", p.rule);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(!p.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 0), p.edits.len);
}

test "rust macro format strings are excluded" {
    const allocator = std.testing.allocator;
    const source =
        \\fn f() {
        \\    println!("x");
        \\    println!("x");
        \\    println!("x");
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .rust);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "c sharp single class placement" {
    const allocator = std.testing.allocator;
    const source =
        \\using System;
        \\
        \\class C {
        \\    void M() {
        \\        var a = "hello";
        \\        var b = "hello";
        \\        var c = "hello";
        \\    }
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .c_sharp);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "using System;\n" ++
            "\n" ++
            "class C {\n" ++
            "    const string HELLO = \"hello\";\n" ++
            "    void M() {\n" ++
            "        var a = HELLO;\n" ++
            "        var b = HELLO;\n" ++
            "        var c = HELLO;\n" ++
            "    }\n" ++
            "}\n",
        candidate,
    );
}

test "c sharp multi class stays advisory" {
    const allocator = std.testing.allocator;
    const source =
        \\class A {
        \\    void M() {
        \\        var a = "hello";
        \\        var b = "hello";
        \\    }
        \\}
        \\
        \\class B {
        \\    void N() {
        \\        var c = "hello";
        \\    }
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .c_sharp);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const p = proposals[0];
    try std.testing.expectEqual(proposal.ProposalKind.constant, p.kind);
    try std.testing.expectEqualStrings("repeated-literal", p.rule);
    try std.testing.expect(p.naming_required);
    try std.testing.expect(!p.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 0), p.edits.len);
    try std.testing.expect(std.mem.indexOf(u8, p.message, "classes") != null);
}

test "c sharp int and bool literals extract inside the class" {
    const allocator = std.testing.allocator;
    const source =
        \\class C {
        \\    bool a = true;
        \\    bool b = true;
        \\    bool c = true;
        \\    int x = 42;
        \\    int y = 42;
        \\    int z = 42;
        \\}
        \\
    ;

    const proposals = try collectForTest(allocator, source, .c_sharp);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 2), proposals.len);

    const bool_candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(bool_candidate);
    try std.testing.expect(std.mem.indexOf(u8, bool_candidate, "    const bool TRUE = true;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bool_candidate, "    bool a = TRUE;\n") != null);

    const int_candidate = try candidateFor(allocator, source, proposals[1]);
    defer allocator.free(int_candidate);
    try std.testing.expect(std.mem.indexOf(u8, int_candidate, "    const int L_42 = 42;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, int_candidate, "    int x = L_42;\n") != null);
}

test "typescript tagged templates stay untouched" {
    const allocator = std.testing.allocator;
    const source =
        \\const a = sql`select 1`;
        \\const b = sql`select 1`;
        \\const c = sql`select 1`;
        \\
    ;

    const proposals = try collectForTest(allocator, source, .typescript);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "tsx jsx attribute strings stay untouched" {
    const allocator = std.testing.allocator;
    const source =
        \\const a = <div className="card" />;
        \\const b = <div className="card" />;
        \\const c = <div className="card" />;
        \\
    ;

    const proposals = try collectForTest(allocator, source, .tsx);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 0), proposals.len);
}

test "python without imports keeps module docstring first" {
    const allocator = std.testing.allocator;
    const source =
        \\"""Module docstring."""
        \\
        \\a = "ACTIVE"
        \\b = "ACTIVE"
        \\c = "ACTIVE"
        \\
    ;

    const proposals = try collectForTest(allocator, source, .python);
    defer deinitProposals(allocator, proposals);

    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    const candidate = try candidateFor(allocator, source, proposals[0]);
    defer allocator.free(candidate);
    try std.testing.expect(std.mem.startsWith(u8, candidate, "\"\"\"Module docstring.\"\"\"\n"));
    try std.testing.expectEqualStrings(
        "\"\"\"Module docstring.\"\"\"\n" ++
            "ACTIVE = \"ACTIVE\"\n" ++
            "\n" ++
            "a = ACTIVE\n" ++
            "b = ACTIVE\n" ++
            "c = ACTIVE\n",
        candidate,
    );
}
