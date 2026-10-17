const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const noise = @import("../../analysis/noise.zig");
const deps_mod = @import("../deps.zig");
const rewriter = @import("../../mutation/rewriter.zig");
const grammars = @import("../../treesitter/grammars.zig");

const ToolResult = common.ToolResult;

const Args = struct {
    filepath: []const u8 = "",
};

fn parseArgs(args: ?std.json.Value) Args {
    return .{
        .filepath = common.getStringArg(args, "filepath") orelse "",
    };
}

pub fn executeRefactorHelperWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    const parsed = parseArgs(args);
    const filepath = parsed.filepath;
    const content = deps.fs.readFileAlloc(allocator, filepath) catch {
        const text = try std.fmt.allocPrint(allocator, "Refactor Helper ({s}): No repeated literals or boolean simplifications required.", .{filepath});
        return ToolResult{ .text = text, .is_error = false };
    };
    defer allocator.free(content);

    const lang = grammars.Language.fromPath(filepath);
    var findings: []noise.NoiseFinding = &.{};
    if (lang != .unknown) {
        findings = deps.auditNoiseWithOptions(allocator, content, lang, .{}) catch &.{};
    }
    defer if (findings.len > 0) noise.deinitFindings(allocator, findings);

    var repeated_count: usize = 0;
    var ternary_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .repeated_literal) repeated_count += 1;
        if (f.rule == .redundant_ternary) ternary_count += 1;
    }

    const simplified = deps.simplify(allocator, content) catch null;
    defer if (simplified) |s| allocator.free(s);

    const has_algebraic = if (simplified) |s| !std.mem.eql(u8, s, content) else false;

    if (repeated_count == 0 and ternary_count == 0 and !has_algebraic) {
        const text = try std.fmt.allocPrint(allocator, "Refactor Helper ({s}): No repeated literals or boolean simplifications required.", .{filepath});
        return ToolResult{ .text = text, .is_error = false };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Refactor Helper ({s}):\n", .{filepath});
    for (findings) |f| {
        if (f.rule == .repeated_literal or f.rule == .redundant_ternary) {
            try buf.print(allocator, "  Line {d}: [{s}] {s}\n", .{ f.line, f.rule.asString(), f.message });
        }
    }
    if (has_algebraic) {
        try buf.appendSlice(allocator, "  Boolean simplification candidate detected: algebraic reduction available via safe_refactor.\n");
    }

    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

pub fn executeRefactorHelper(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeRefactorHelperWithDeps(allocator, args, &default);
}
