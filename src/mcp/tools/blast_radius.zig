const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const fmt = @import("../format.zig");
const blast = @import("../../analysis/blast.zig");
const deps_mod = @import("../deps.zig");
const grammars = @import("../../treesitter/grammars.zig");
const ledger_mod = @import("../../storage/ledger.zig");

const ToolResult = common.ToolResult;

const Args = struct {
    symbol: []const u8 = "",
    root: []const u8 = ".",
    format: []const u8 = "text",
};

fn parseArgs(args: ?std.json.Value) Args {
    return .{
        .symbol = common.getStringArg(args, "symbol") orelse "",
        .root = common.getStringArg(args, "root") orelse ".",
        .format = common.getStringArg(args, "format") orelse "text",
    };
}

pub fn executeBlastRadiusWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const symbol = parsed.symbol;
    const root_dir = parsed.root;
    const format = parsed.format;

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

    try loadBlastFiles(allocator, deps, &files_list, &file_inputs);

    var result = try deps.analyzeBlastRadius(allocator, file_inputs.items, symbol);
    defer result.deinit(allocator);

    if (deps.db.open(allocator, root_dir)) |db_inst| {
        var db = db_inst;
        defer db.close();
        var ledger = ledger_mod.RefactorLedger.init(db, allocator);
        for (result.references) |ref| {
            ledger.recordSymbol(symbol, ref.file, ref.line, ref.column, ref.is_definition) catch {};
        }
    } else |_| {}

    var defs_count: u32 = 0;
    var refs_count: u32 = 0;
    for (result.references) |ref| {
        if (ref.is_definition) defs_count += 1 else refs_count += 1;
    }

    return fmt.blastRadius(allocator, symbol, defs_count, refs_count, result.files_count, result.risk.asString(), result.references, format);
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
