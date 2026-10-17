const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const FunctionRecord = struct {
    name: []const u8,
    line: u32,
    end_line: u32,
    complexity: u32,

    pub fn deinit(self: FunctionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub fn calculateComplexity(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) ![]FunctionRecord {
    const ts_lang = lang.getTsLanguage() orelse return &.{};

    const cache_key = CacheKey{ .lang = lang, .hash = std.hash.Wyhash.hash(0, source) };
    if (lookupComplexityCache(allocator, cache_key)) |cached| {
        return cached;
    }

    var parser = try bindings.Parser.init();
    defer parser.deinit();

    if (!parser.setLanguage(ts_lang)) return error.SetLanguageFailed;

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const root = tree.rootNode();
    var records: std.ArrayList(FunctionRecord) = .empty;
    defer records.deinit(allocator);

    try collectFunctions(allocator, root, source, lang, &records);

    const owned = try records.toOwnedSlice(allocator);
    try storeComplexityCache(cache_key, owned);
    const cloned = try cloneComplexityRecords(allocator, owned);
    // free owned (names owned)
    for (owned) |r| allocator.free(r.name);
    allocator.free(owned);
    return cloned;
}

const CacheKey = struct { lang: grammars.Language, hash: u64 };

var complexity_cache_key: ?CacheKey = null;
var complexity_cache_value: []FunctionRecord = &.{};

fn lookupComplexityCache(allocator: std.mem.Allocator, key: CacheKey) ?[]FunctionRecord {
    if (complexity_cache_key) |k| {
        if (k.lang == key.lang and k.hash == key.hash) {
            return cloneComplexityRecords(allocator, complexity_cache_value) catch null;
        }
    }
    return null;
}

fn storeComplexityCache(key: CacheKey, value: []const FunctionRecord) !void {
    // Free previous cached value (names owned).
    for (complexity_cache_value) |r| {
        std.heap.page_allocator.free(r.name);
    }
    if (complexity_cache_value.len > 0) {
        std.heap.page_allocator.free(complexity_cache_value);
    }

    const cached = try std.heap.page_allocator.alloc(FunctionRecord, value.len);
    errdefer std.heap.page_allocator.free(cached);
    for (value, 0..) |r, i| {
        cached[i] = .{
            .name = try std.heap.page_allocator.dupe(u8, r.name),
            .line = r.line,
            .end_line = r.end_line,
            .complexity = r.complexity,
        };
    }
    complexity_cache_value = cached;
    complexity_cache_key = key;
}

fn cloneComplexityRecords(allocator: std.mem.Allocator, src: []const FunctionRecord) ![]FunctionRecord {
    const out = try allocator.alloc(FunctionRecord, src.len);
    errdefer allocator.free(out);
    for (src, 0..) |r, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, r.name),
            .line = r.line,
            .end_line = r.end_line,
            .complexity = r.complexity,
        };
    }
    return out;
}

fn collectFunctions(
    allocator: std.mem.Allocator,
    node: bindings.TSNode,
    source: []const u8,
    lang: grammars.Language,
    records: *std.ArrayList(FunctionRecord),
) !void {
    if (node.isNull()) return;

    if (lang.isFunctionNode(node)) {
        const name = getFunctionName(node, source, lang);
        const start = node.startPoint();
        const end = node.endPoint();

        var score: u32 = 0;
        walkNode(node, source, lang, 0, &score, true);

        try records.append(allocator, .{
            .name = try allocator.dupe(u8, name),
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

fn getFunctionName(node: bindings.TSNode, source: []const u8, lang: grammars.Language) []const u8 {
    const name_node = node.childByFieldName("name");
    if (!name_node.isNull()) {
        const name_slice = name_node.slice(source);
        if (name_slice.len > 0) return name_slice;
    }

    const t = node.getType();
    if (lang == .c_sharp and std.mem.eql(u8, t, "constructor_declaration")) {
        return resolveCSharpConstructorName(node, source);
    }
    if ((lang == .typescript or lang == .tsx) and std.mem.eql(u8, t, "method_definition")) {
        return resolveTypeScriptMethodName(node, source);
    }
    if (lang == .go and std.mem.eql(u8, t, "method_declaration")) {
        return resolveGoMethodName(node, source);
    }
    return "anonymous";
}

fn resolveCSharpConstructorName(node: bindings.TSNode, source: []const u8) []const u8 {
    var curr = node.parent();
    while (!curr.isNull()) {
        const pt = curr.getType();
        if (std.mem.eql(u8, pt, "class_declaration") or
            std.mem.eql(u8, pt, "struct_declaration") or
            std.mem.eql(u8, pt, "record_declaration"))
        {
            const parent_name = curr.childByFieldName("name");
            if (!parent_name.isNull()) {
                const s = parent_name.slice(source);
                if (s.len > 0) return s;
            }
            break;
        }
        curr = curr.parent();
    }
    return "constructor";
}

fn resolveTypeScriptMethodName(node: bindings.TSNode, source: []const u8) []const u8 {
    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        const ch = node.child(i);
        if (std.mem.eql(u8, ch.getType(), "property_identifier")) {
            const s = ch.slice(source);
            if (s.len > 0) return s;
        }
    }
    return "constructor";
}

fn resolveGoMethodName(node: bindings.TSNode, source: []const u8) []const u8 {
    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        const ch = node.child(i);
        if (std.mem.eql(u8, ch.getType(), "field_identifier")) {
            const s = ch.slice(source);
            if (s.len > 0) return s;
        }
    }
    return "anonymous";
}

fn walkNode(
    node: bindings.TSNode,
    source: []const u8,
    lang: grammars.Language,
    nesting: u32,
    score: *u32,
    is_root: bool,
) void {
    if (node.isNull()) return;

    if (!is_root and lang.isFunctionNode(node)) return;

    const t = node.getType();

    // Explicitly ignore optional chaining and nullable types
    if (isIgnoredNode(t)) return;

    var next_nesting = nesting;
    next_nesting = applyComplexityForNode(node, t, lang, source, nesting, score, is_root);

    const is_var_decl = is_root and std.mem.eql(u8, t, "variable_declarator");

    var i: u32 = 0;
    const count = node.childCount();
    while (i < count) : (i += 1) {
        const ch = node.child(i);
        const child_nesting = if (lang == .python and (std.mem.eql(u8, ch.getType(), "elif_clause") or std.mem.eql(u8, ch.getType(), "else_clause")))
            nesting
        else
            next_nesting;
        const ch_type = ch.getType();
        const ch_is_root = is_var_decl and (std.mem.eql(u8, ch_type, "arrow_function") or std.mem.eql(u8, ch_type, "function_expression"));
        walkNode(ch, source, lang, child_nesting, score, ch_is_root);
    }
}

fn applyComplexityForNode(node: bindings.TSNode, t: []const u8, lang: grammars.Language, source: []const u8, nesting: u32, score: *u32, is_root: bool) u32 {
    if (lang.isIfNode(t)) {
        if (lang.isElseIfNode(node)) {
            score.* += 1;
        } else {
            score.* += 1 + nesting;
        }
        return nesting + 1;
    }
    if (lang.isElseNode(node)) {
        score.* += 1;
        return nesting + 1;
    }
    if (lang.isTernaryNode(t)) {
        score.* += 1 + nesting;
        return nesting + 1;
    }
    if (lang.isSwitchNode(t)) {
        score.* += 1 + nesting;
        return nesting + 1;
    }
    if (lang.isLoopNode(t)) {
        score.* += 1 + nesting;
        return nesting + 1;
    }
    if (lang.isCatchNode(t)) {
        score.* += 1 + nesting;
        return nesting + 1;
    }
    if (lang.isClosure(t)) {
        if (is_root) return nesting;
        return nesting + 1;
    }
    scoreLogicalOperator(node, source, lang, score);
    return nesting;
}

fn scoreLogicalOperator(node: bindings.TSNode, source: []const u8, lang: grammars.Language, score: *u32) void {
    const op = getLogicalOperator(node, source, lang) orelse return;
    if (!parentHasSameLogicalOperator(node, op, source, lang)) {
        score.* += 1;
    }
}

fn isIgnoredNode(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "nullable_type") or
        std.mem.eql(u8, node_type, "conditional_access_expression") or
        std.mem.eql(u8, node_type, "optional_chain");
}

fn getLogicalOperator(node: bindings.TSNode, source: []const u8, lang: grammars.Language) ?[]const u8 {
    return grammars.getLogicalOperator(node, source, lang);
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
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

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
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

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
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

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
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("Process", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 3), funcs[0].complexity);
}

test "calculateComplexity - outer function does not double-count inner function statements" {
    const source =
        \\function outer(a: boolean): void {
        \\    if (a) {
        \\        doA();
        \\    }
        \\    function inner(b: boolean): void {
        \\        if (b) {
        \\            doB();
        \\        }
        \\    }
        \\}
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .typescript);
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

    try std.testing.expectEqual(@as(usize, 2), funcs.len);
    try std.testing.expectEqualStrings("outer", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
    try std.testing.expectEqualStrings("inner", funcs[1].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[1].complexity);
}

test "calculateComplexity - C# and TypeScript constructors resolve name instead of anonymous" {
    // TypeScript constructor
    {
        const source =
            \\class UserService {
            \\    constructor(config: any) {
            \\        if (config.ready) {
            \\            init();
            \\        }
            \\    }
            \\}
        ;

        const funcs = try calculateComplexity(std.testing.allocator, source, .typescript);
        defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

        try std.testing.expectEqual(@as(usize, 1), funcs.len);
        try std.testing.expectEqualStrings("constructor", funcs[0].name);
        try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
    }

    // C# constructor
    {
        const source =
            \\public class OrderProcessor {
            \\    public OrderProcessor(int id) {
            \\        if (id > 0) {
            \\            Process();
            \\        }
            \\    }
            \\}
        ;

        const funcs = try calculateComplexity(std.testing.allocator, source, .c_sharp);
        defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

        try std.testing.expectEqual(@as(usize, 1), funcs.len);
        try std.testing.expect(std.mem.eql(u8, funcs[0].name, "OrderProcessor") or std.mem.eql(u8, funcs[0].name, "constructor"));
        try std.testing.expect(!std.mem.eql(u8, funcs[0].name, "anonymous"));
        try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
    }
}

test "calculateComplexity - Python and C# nested functions do not double count" {
    // Python nested function
    {
        const source =
            \\def outer(x):
            \\    if x > 0:
            \\        pass
            \\    def inner(y):
            \\        if y > 0:
            \\            pass
        ;

        const funcs = try calculateComplexity(std.testing.allocator, source, .python);
        defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

        try std.testing.expectEqual(@as(usize, 2), funcs.len);
        try std.testing.expectEqualStrings("outer", funcs[0].name);
        try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
        try std.testing.expectEqualStrings("inner", funcs[1].name);
        try std.testing.expectEqual(@as(u32, 1), funcs[1].complexity);
    }

    // C# local function
    {
        const source =
            \\public class Worker {
            \\    public void Run(bool flag) {
            \\        if (flag) {}
            \\        void Helper(bool inner) {
            \\            if (inner) {}
            \\        }
            \\    }
            \\}
        ;

        const funcs = try calculateComplexity(std.testing.allocator, source, .c_sharp);
        defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

        try std.testing.expectEqual(@as(usize, 2), funcs.len);
        try std.testing.expectEqualStrings("Run", funcs[0].name);
        try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
        try std.testing.expectEqualStrings("Helper", funcs[1].name);
        try std.testing.expectEqual(@as(u32, 1), funcs[1].complexity);
    }
}

test "calculateComplexity - Go method with receiver name resolution" {
    const source =
        \\package main
        \\
        \\type Service struct{}
        \\
        \\func (s *Service) Execute(x int) bool {
        \\    if x > 0 {
        \\        return true
        \\    }
        \\    return false
        \\}
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .go);
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("Execute", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
}

test "calculateComplexity - Python elif does not double nest" {
    const source =
        \\def check(x, y):
        \\    if x == 1:
        \\        if y == 1:
        \\            pass
        \\    elif x == 2:
        \\        if y == 2:
        \\            pass
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .python);
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("check", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 6), funcs[0].complexity);
}

test "calculateComplexity - TypeScript arrow function in variable_declarator" {
    const source =
        \\const check = (a: boolean) => {
        \\    if (a) {
        \\        doSomething();
        \\    }
        \\};
    ;

    const funcs = try calculateComplexity(std.testing.allocator, source, .typescript);
    defer { for (funcs) |f| f.deinit(std.testing.allocator); std.testing.allocator.free(funcs); }

    try std.testing.expectEqual(@as(usize, 1), funcs.len);
    try std.testing.expectEqualStrings("check", funcs[0].name);
    try std.testing.expectEqual(@as(u32, 1), funcs[0].complexity);
}
