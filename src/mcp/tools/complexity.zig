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

const Args = struct {
    path: []const u8 = ".",
    threshold: u32 = 15,
    format: []const u8 = "text",
};

fn parseArgs(args: ?std.json.Value) Args {
    return .{
        .path = common.getStringArg(args, "path") orelse ".",
        .threshold = common.getU32Arg(args, "threshold", 15),
        .format = common.getStringArg(args, "format") orelse "text",
    };
}

pub fn executeComplexityWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const path = parsed.path;
    const threshold = parsed.threshold;
    const format = parsed.format;

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

    for (files_list.items) |file_path| {
        const lang = grammars.Language.fromPath(file_path);
        if (lang == .unknown) continue;

        const content = deps.fs.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        const records = deps.calculateComplexity(allocator, content, lang) catch continue;
        defer allocator.free(records);

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

    var exceeded_count: usize = 0;
    for (all_funcs.items) |item| {
        if (item.complexity >= threshold) exceeded_count += 1;
    }

    return fmt.complexity(allocator, path, threshold, all_funcs, exceeded_count, format);
}

pub fn executeComplexity(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeComplexityWithDeps(allocator, args, &default);
}
