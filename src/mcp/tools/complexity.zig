const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const fmt = @import("../format.zig");
const complexity = @import("../../analysis/complexity.zig");
const deps_mod = @import("../deps.zig");
const grammars = @import("../../treesitter/grammars.zig");

const ToolResult = common.ToolResult;

pub const FuncItem = struct {
    file: []const u8,
    name: []const u8,
    line: u32,
    end_line: u32,
    complexity: u32,

    pub fn deinit(self: FuncItem, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.name);
    }
};

pub const ComplexityParams = struct {
    path: []const u8 = ".",
    threshold: u32 = 15,
    format: []const u8 = "text",
};

fn parseArgs(args: ?std.json.Value) ComplexityParams {
    return .{
        .path = common.getStringArg(args, "path") orelse ".",
        .threshold = common.getU32Arg(args, "threshold", 15),
        .format = common.getStringArg(args, "format") orelse "text",
    };
}

pub fn executeComplexityDirect(allocator: std.mem.Allocator, params: ComplexityParams, deps: *const deps_mod.Deps) !ToolResult {
    const path = params.path;
    const threshold = params.threshold;
    const format = params.format;

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try common.collectSourceFiles(allocator, path, &files_list);

    var all_funcs: std.ArrayList(FuncItem) = .empty;
    defer {
        for (all_funcs.items) |item| item.deinit(allocator);
        all_funcs.deinit(allocator);
    }

    var file_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer file_arena.deinit();

    for (files_list.items) |file_path| {
        _ = file_arena.reset(.retain_capacity);
        try appendComplexityRecords(allocator, file_arena.allocator(), deps, file_path, threshold, format, &all_funcs);
    }

    std.mem.sort(FuncItem, all_funcs.items, {}, sortFuncs);

    var exceeded_count: usize = 0;
    for (all_funcs.items) |item| {
        if (item.complexity >= threshold) exceeded_count += 1;
    }

    return fmt.complexity(allocator, path, threshold, all_funcs, exceeded_count, format);
}

pub fn executeComplexityWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    return executeComplexityDirect(allocator, parsed, deps);
}

fn sortFuncs(_: void, a: FuncItem, b: FuncItem) bool {
    const file_cmp = std.mem.order(u8, a.file, b.file);
    if (file_cmp == .lt) return true;
    if (file_cmp == .gt) return false;
    return a.line < b.line;
}

pub fn executeComplexity(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeComplexityWithDeps(allocator, args, &default);
}

fn appendComplexityRecords(
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    file_path: []const u8,
    threshold: u32,
    format: []const u8,
    all_funcs: *std.ArrayList(FuncItem),
) !void {
    const lang = grammars.Language.fromPath(file_path);
    if (lang == .unknown) return;

    const content = deps.fs.readFileAlloc(temp_allocator, file_path) catch return;

    const records = deps.calculateComplexity(temp_allocator, content, lang) catch return;

    for (records) |rec| {
        if (rec.complexity >= threshold or std.mem.eql(u8, format, "json") or std.mem.eql(u8, format, "sarif")) {
            try all_funcs.append(allocator, .{
                .file = try allocator.dupe(u8, file_path),
                .name = try allocator.dupe(u8, rec.name),
                .line = rec.line,
                .end_line = rec.end_line,
                .complexity = rec.complexity,
            });
        }
    }
}
