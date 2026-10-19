const std = @import("std");
const common = @import("../common.zig");
const compact = @import("../compact.zig");
const noise = @import("../../analysis/noise.zig");
const deps_mod = @import("../deps.zig");
const rewriter = @import("../../mutation/rewriter.zig");
const grammars = @import("../../treesitter/grammars.zig");
const proposal = @import("../../mutation/proposal.zig");
const propose = @import("../../mutation/propose.zig");

const ToolResult = common.ToolResult;

const KIND_COUNT = std.enums.values(proposal.ProposalKind).len;

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

    const repeated_count = countFindings(findings, .repeated_literal);
    const ternary_count = countFindings(findings, .redundant_ternary);

    var proposal_counts: [KIND_COUNT]usize = @splat(0);
    if (lang != .unknown) {
        var collected: ?propose.CollectResult = deps.collectProposals(allocator, content, lang, .{}) catch null;
        defer if (collected) |*result| propose.deinitCollectResult(allocator, result);
        if (collected) |result| {
            for (result.proposals) |p| proposal_counts[@backingInt(p.kind)] += 1;
        }
    }

    const simplified = deps.simplify(allocator, content) catch null;
    defer if (simplified) |s| allocator.free(s);

    const has_algebraic = if (simplified) |s| !std.mem.eql(u8, s, content) else false;

    if (repeated_count == 0 and ternary_count == 0 and !has_algebraic and !hasAnyProposals(proposal_counts)) {
        const text = try std.fmt.allocPrint(allocator, "Refactor Helper ({s}): No repeated literals or boolean simplifications required.", .{filepath});
        return ToolResult{ .text = text, .is_error = false };
    }

    const text = try buildRefactorHelperText(allocator, filepath, findings, has_algebraic, proposal_counts);
    return ToolResult{ .text = text, .is_error = false };
}

fn hasAnyProposals(proposal_counts: [KIND_COUNT]usize) bool {
    for (proposal_counts) |count| {
        if (count > 0) return true;
    }
    return false;
}

fn countFindings(findings: []noise.NoiseFinding, rule: noise.NoiseRule) usize {
    var count: usize = 0;
    for (findings) |f| {
        if (f.rule == rule) count += 1;
    }
    return count;
}

fn buildRefactorHelperText(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    findings: []noise.NoiseFinding,
    has_algebraic: bool,
    proposal_counts: [KIND_COUNT]usize,
) ![]u8 {
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
    if (hasAnyProposals(proposal_counts)) {
        try buf.appendSlice(allocator, "Proposals: ");
        var first = true;
        for (std.enums.values(proposal.ProposalKind)) |kind| {
            const count = proposal_counts[@backingInt(kind)];
            if (count == 0) continue;
            if (!first) try buf.append(allocator, ' ');
            first = false;
            try buf.print(allocator, "{s}={d}", .{ proposal.kindName(kind), count });
        }
        try buf.appendSlice(allocator, " (run propose_fixes or plan for patches).\n");
    }
    return buf.toOwnedSlice(allocator);
}

test "refactor helper appends proposal summary and keeps existing lines" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const filepath = "tests/test_refactor_helper_props.ts";
    const fixture =
        \\function process(user: User): void {
        \\  if (user.isActive) {
        \\    log("dup_value");
        \\    log("dup_value");
        \\    log("dup_value");
        \\  }
        \\}
        \\
    ;
    const file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, filepath) catch {};

    const default = deps_mod.defaultDeps();
    const args_json = "{\"filepath\":\"" ++ filepath ++ "\"}";
    var args = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer args.deinit();
    const res = try executeRefactorHelperWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);

    try std.testing.expect(!res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "Proposals: guard=1 constant=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "  Line 3: [repeated-literal]") != null);
}

pub fn executeRefactorHelper(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeRefactorHelperWithDeps(allocator, args, &default);
}
