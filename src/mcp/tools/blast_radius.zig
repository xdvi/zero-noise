const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const fmt = @import("../format.zig");
const blast = @import("../../analysis/blast.zig");
const deps_mod = @import("../deps.zig");
const grammars = @import("../../treesitter/grammars.zig");
const ledger_mod = @import("../../storage/ledger.zig");

const ToolResult = common.ToolResult;

pub const BlastRadiusParams = struct {
    symbol: []const u8 = "",
    root: []const u8 = ".",
    format: []const u8 = "text",
};

fn parseArgs(args: ?std.json.Value) BlastRadiusParams {
    return .{
        .symbol = common.getStringArg(args, "symbol") orelse "",
        .root = common.getStringArg(args, "root") orelse ".",
        .format = common.getStringArg(args, "format") orelse "text",
    };
}

pub fn executeBlastRadiusDirect(allocator: std.mem.Allocator, params: BlastRadiusParams, deps: *const deps_mod.Deps) !ToolResult {
    const symbol = params.symbol;
    const root_dir = params.root;
    const format = params.format;

    if (symbol.len == 0) {
        return ToolResult{ .text = try allocator.dupe(u8, "Error: symbol argument is required"), .is_error = true };
    }

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try common.collectSourceFiles(allocator, root_dir, &files_list);

    var file_inputs: std.ArrayList(blast.FileInput) = .empty;
    defer {
        for (file_inputs.items) |fi| allocator.free(fi.content);
        file_inputs.deinit(allocator);
    }

    var references: std.ArrayList(blast.SymbolReference) = .empty;
    defer references.deinit(allocator);

    var files_with_usages = std.StringHashMap(void).init(allocator);
    defer files_with_usages.deinit();

    for (files_list.items) |fp| {
        const content = deps.fs.readFileAlloc(allocator, fp) catch continue;
        defer allocator.free(content);

        const file_refs = blast.scanFileReferences(allocator, fp, content, symbol) catch continue;
        defer allocator.free(file_refs);

        if (file_refs.len == 0) continue;
        files_with_usages.put(fp, {}) catch {};
        for (file_refs) |ref| {
            try references.append(allocator, ref);
        }
    }

    const files_count: u32 = @intCast(files_with_usages.count());
    const risk = blast.calculateRisk(files_count);

    const result_refs = try references.toOwnedSlice(allocator);

    if (deps.db.open(allocator, root_dir)) |db_inst| {
        var db = db_inst;
        defer db.close();
        var ledger = ledger_mod.RefactorLedger.init(&db, allocator);
        for (result_refs) |ref| {
            ledger.recordSymbol(symbol, ref.file, ref.line, ref.column, ref.is_definition) catch {};
        }
    } else |_| {}

    var defs_count: u32 = 0;
    var refs_count: u32 = 0;
    for (result_refs) |ref| {
        if (ref.is_definition) defs_count += 1 else refs_count += 1;
    }

    const tool_result = try fmt.blastRadius(allocator, symbol, defs_count, refs_count, files_count, risk.asString(), result_refs, format);
    allocator.free(result_refs);
    return tool_result;
}

pub fn executeBlastRadiusWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    return executeBlastRadiusDirect(allocator, parsed, deps);
}

pub fn executeBlastRadius(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeBlastRadiusWithDeps(allocator, args, &default);
}

fn loadBlastFiles(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    files_list: *std.ArrayList([]const u8),
    file_inputs: *std.ArrayList(blast.FileInput),
) !void {
    for (files_list.items) |fp| {
        const content = deps.fs.readFileAlloc(allocator, fp) catch continue;
        try file_inputs.append(allocator, .{ .path = fp, .content = content });
    }
}
