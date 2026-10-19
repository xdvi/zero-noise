const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");
const proposal = @import("proposal.zig");
const rewrite_closures = @import("rewrite_closures.zig");
const rewrite_constants = @import("rewrite_constants.zig");
const rewrite_guards = @import("rewrite_guards.zig");
const rewrite_predicates = @import("rewrite_predicates.zig");

pub const KindFlags = struct {
    guard: bool = true,
    predicate: bool = true,
    constant: bool = true,
    closure: bool = true,
    boolean: bool = false,
};

pub const Capability = enum { enabled, advisory };

pub const PassFn = *const fn (std.mem.Allocator, []const u8, grammars.Language, bindings.TSNode) anyerror![]proposal.Proposal;

pub const PassDef = struct {
    kind: proposal.ProposalKind,
    supportedLanguages: *const fn () []const grammars.Language,
    collect: PassFn,
};

/// Registry of pass modules, in deterministic limitation-report order.
pub const passes = [_]PassDef{
    .{ .kind = .guard, .supportedLanguages = rewrite_guards.supportedLanguages, .collect = rewrite_guards.collect },
    .{ .kind = .constant, .supportedLanguages = rewrite_constants.supportedLanguages, .collect = rewrite_constants.collect },
    .{ .kind = .predicate, .supportedLanguages = rewrite_predicates.supportedLanguages, .collect = rewrite_predicates.collect },
    .{ .kind = .closure, .supportedLanguages = rewrite_closures.supportedLanguages, .collect = rewrite_closures.collect },
};

pub const CollectResult = struct {
    proposals: []proposal.Proposal,
    limitations: [][]const u8,
    parse_error: bool,
};

fn passFor(kind: proposal.ProposalKind) ?PassDef {
    for (passes) |pass_def| {
        if (pass_def.kind == kind) return pass_def;
    }
    return null;
}

/// A kind is enabled when its pass lists the language; text-rewriter kinds
/// (`boolean`) stay enabled for every known language.
pub fn capabilityFor(kind: proposal.ProposalKind, lang: grammars.Language) Capability {
    const pass_def = passFor(kind) orelse {
        return if (lang == .unknown) .advisory else .enabled;
    };
    for (pass_def.supportedLanguages()) |supported| {
        if (supported == lang) return .enabled;
    }
    return .advisory;
}

/// Parses once, runs the flagged passes whose capability is enabled, assigns
/// the source SHA-256 to every proposal, then sorts and deduplicates them.
pub fn collectProposals(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    flags: KindFlags,
) !CollectResult {
    return collectWithPasses(allocator, source, lang, flags, &passes);
}

fn collectWithPasses(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    flags: KindFlags,
    pass_defs: []const PassDef,
) !CollectResult {
    var limitations: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (limitations.items) |limitation| allocator.free(limitation);
        limitations.deinit(allocator);
    }

    const ts_lang = lang.getTsLanguage() orelse {
        try limitations.append(allocator, try std.fmt.allocPrint(
            allocator,
            "language not supported: {s}",
            .{@tagName(lang)},
        ));
        return .{
            .proposals = &.{},
            .limitations = try limitations.toOwnedSlice(allocator),
            .parse_error = false,
        };
    };

    var parser = try bindings.getThreadParser();
    if (!parser.setLanguage(ts_lang)) return error.SetLanguageFailed;

    var tree = try parser.parseString(source);
    defer tree.deinit();

    const root = tree.rootNode();

    var proposals: std.ArrayList(proposal.Proposal) = .empty;
    errdefer {
        for (proposals.items) |p| p.deinit(allocator);
        proposals.deinit(allocator);
    }

    if (root.hasError()) {
        try limitations.append(allocator, try std.fmt.allocPrint(
            allocator,
            "parse error: file has syntax errors; no proposals",
            .{},
        ));
        return .{
            .proposals = &.{},
            .limitations = try limitations.toOwnedSlice(allocator),
            .parse_error = true,
        };
    }

    for (pass_defs) |pass_def| {
        if (!kindEnabled(flags, pass_def.kind)) continue;

        if (!supportsLanguage(pass_def, lang)) {
            try limitations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s} extraction not enabled for {s} (advisory)",
                .{ proposal.kindName(pass_def.kind), @tagName(lang) },
            ));
            continue;
        }

        {
            const produced = try pass_def.collect(allocator, source, lang, root);
            errdefer {
                for (produced) |p| p.deinit(allocator);
                allocator.free(produced);
            }
            try proposals.appendSlice(allocator, produced);
            allocator.free(produced);
        }
    }

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(source);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const hash_hex = std.fmt.bytesToHex(digest, .lower);

    for (proposals.items) |*p| {
        if (p.expected_hash.len > 0) allocator.free(p.expected_hash);
        p.expected_hash = try allocator.dupe(u8, &hash_hex);
    }

    std.mem.sort(proposal.Proposal, proposals.items, {}, proposalLessThan);
    deduplicateProposals(allocator, &proposals);

    const owned_limitations = try limitations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_limitations);

    return .{
        .proposals = try proposals.toOwnedSlice(allocator),
        .limitations = owned_limitations,
        .parse_error = false,
    };
}

pub fn deinitCollectResult(allocator: std.mem.Allocator, self: *CollectResult) void {
    for (self.proposals) |p| p.deinit(allocator);
    allocator.free(self.proposals);
    for (self.limitations) |limitation| allocator.free(limitation);
    allocator.free(self.limitations);
}

fn kindEnabled(flags: KindFlags, kind: proposal.ProposalKind) bool {
    return switch (kind) {
        .guard => flags.guard,
        .predicate => flags.predicate,
        .constant => flags.constant,
        .closure => flags.closure,
        .boolean => flags.boolean,
    };
}

fn supportsLanguage(pass_def: PassDef, lang: grammars.Language) bool {
    for (pass_def.supportedLanguages()) |supported| {
        if (supported == lang) return true;
    }
    return false;
}

fn proposalLessThan(_: void, a: proposal.Proposal, b: proposal.Proposal) bool {
    if (a.line != b.line) return a.line < b.line;
    if (a.col != b.col) return a.col < b.col;
    if (a.kind != b.kind) {
        const order = std.mem.order(u8, proposal.kindName(a.kind), proposal.kindName(b.kind));
        if (order != .eq) return order == .lt;
    }
    return std.mem.lessThan(u8, a.rule, b.rule);
}

/// Keeps the first proposal per (kind, line, col) after sorting.
fn deduplicateProposals(allocator: std.mem.Allocator, proposals: *std.ArrayList(proposal.Proposal)) void {
    var write: usize = 0;
    for (proposals.items) |p| {
        if (write > 0) {
            const kept = proposals.items[write - 1];
            if (kept.kind == p.kind and kept.line == p.line and kept.col == p.col) {
                p.deinit(allocator);
                continue;
            }
        }
        proposals.items[write] = p;
        write += 1;
    }
    proposals.shrinkRetainingCapacity(write);
}

test "unknown language returns empty result with limitation" {
    const allocator = std.testing.allocator;

    var result = try collectProposals(allocator, "const x = 1;", .unknown, .{});
    defer deinitCollectResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 0), result.proposals.len);
    try std.testing.expectEqual(@as(usize, 1), result.limitations.len);
    try std.testing.expect(!result.parse_error);
}

test "parse-error file reports parse_error and no proposals" {
    const allocator = std.testing.allocator;

    var result = try collectProposals(allocator, "const x = ;", .typescript, .{});
    defer deinitCollectResult(allocator, &result);

    try std.testing.expect(result.parse_error);
    try std.testing.expectEqual(@as(usize, 0), result.proposals.len);
}

test "proposals sort deterministically by line, col, kind name" {
    const allocator = std.testing.allocator;
    const source = "const x = 1;\n";

    const test_passes = [_]PassDef{
        .{ .kind = .guard, .supportedLanguages = testSupportsTypescript, .collect = testCollectGuardA },
        .{ .kind = .predicate, .supportedLanguages = testSupportsTypescript, .collect = testCollectPredicateB },
    };

    var first = try collectWithPasses(allocator, source, .typescript, .{}, &test_passes);
    defer deinitCollectResult(allocator, &first);

    var second = try collectWithPasses(allocator, source, .typescript, .{}, &test_passes);
    defer deinitCollectResult(allocator, &second);

    try std.testing.expectEqual(@as(usize, 4), first.proposals.len);
    try std.testing.expectEqual(@as(usize, 4), second.proposals.len);

    const expected = [_]proposal.ProposalKind{ .constant, .predicate, .guard, .guard };
    const expected_lines = [_]u32{ 2, 2, 5, 7 };
    const expected_cols = [_]u32{ 1, 1, 3, 1 };

    for (first.proposals, 0..) |p, i| {
        try std.testing.expectEqual(expected[i], p.kind);
        try std.testing.expectEqual(expected_lines[i], p.line);
        try std.testing.expectEqual(expected_cols[i], p.col);

        const mirror = second.proposals[i];
        try std.testing.expectEqual(p.kind, mirror.kind);
        try std.testing.expectEqual(p.line, mirror.line);
        try std.testing.expectEqual(p.col, mirror.col);
        try std.testing.expectEqualStrings(p.rule, mirror.rule);
    }
}

test "duplicate proposals with same kind, line, col collapse to one" {
    const allocator = std.testing.allocator;
    const source = "const x = 1;\n";

    const test_passes = [_]PassDef{
        .{ .kind = .guard, .supportedLanguages = testSupportsTypescript, .collect = testCollectGuardDuplicate },
        .{ .kind = .guard, .supportedLanguages = testSupportsTypescript, .collect = testCollectGuardDuplicate },
    };

    var result = try collectWithPasses(allocator, source, .typescript, .{}, &test_passes);
    defer deinitCollectResult(allocator, &result);

    var guard_count: usize = 0;
    for (result.proposals) |p| {
        if (p.kind == .guard) guard_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), guard_count);
}

test "every proposal carries the source hash" {
    const allocator = std.testing.allocator;

    const test_passes = [_]PassDef{
        .{ .kind = .guard, .supportedLanguages = testSupportsTypescript, .collect = testCollectGuardA },
    };

    var first = try collectWithPasses(allocator, "const a = 1;\n", .typescript, .{}, &test_passes);
    defer deinitCollectResult(allocator, &first);
    var second = try collectWithPasses(allocator, "const a = 1;\n", .typescript, .{}, &test_passes);
    defer deinitCollectResult(allocator, &second);
    var other = try collectWithPasses(allocator, "const a = 2;\n", .typescript, .{}, &test_passes);
    defer deinitCollectResult(allocator, &other);

    try std.testing.expect(first.proposals.len > 0);
    for (first.proposals) |p| {
        try std.testing.expectEqual(@as(usize, 64), p.expected_hash.len);
        for (p.expected_hash) |ch| {
            try std.testing.expect(std.ascii.isHex(ch));
        }
    }

    try std.testing.expectEqualStrings(first.proposals[0].expected_hash, second.proposals[0].expected_hash);
    try std.testing.expect(!std.mem.eql(u8, first.proposals[0].expected_hash, other.proposals[0].expected_hash));
}

test "advisory capability adds a limitation entry" {
    // Pairs that stay advisory across every P0 pass rollout.
    try std.testing.expectEqual(Capability.advisory, capabilityFor(.predicate, .go));
    try std.testing.expectEqual(Capability.advisory, capabilityFor(.closure, .rust));

    const allocator = std.testing.allocator;
    var result = try collectProposals(allocator, "package main\n\nfunc f() {}\n", .go, .{});
    defer deinitCollectResult(allocator, &result);

    var found = false;
    for (result.limitations) |limitation| {
        if (std.mem.indexOf(u8, limitation, "predicate extraction not enabled for go (advisory)") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

fn testSupportsTypescript() []const grammars.Language {
    return &.{.typescript};
}

fn testCollectGuardA(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    _ = source;
    _ = lang;
    std.debug.assert(!root.isNull());

    const items = try allocator.alloc(proposal.Proposal, 2);
    items[0] = try testProposal(allocator, .guard, "excessive-nesting", 5, 3);
    items[1] = try testProposal(allocator, .guard, "second-guard", 7, 1);
    return items;
}

fn testCollectGuardDuplicate(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    _ = source;
    _ = lang;
    _ = root;

    const items = try allocator.alloc(proposal.Proposal, 1);
    items[0] = try testProposal(allocator, .guard, "duplicate-of-a", 5, 3);
    return items;
}

fn testCollectPredicateB(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    _ = source;
    _ = lang;
    _ = root;

    const items = try allocator.alloc(proposal.Proposal, 2);
    items[0] = try testProposal(allocator, .predicate, "raw-boolean", 2, 1);
    items[1] = try testProposal(allocator, .constant, "repeated-literal", 2, 1);
    return items;
}

fn testProposal(
    allocator: std.mem.Allocator,
    kind: proposal.ProposalKind,
    rule: []const u8,
    line: u32,
    col: u32,
) !proposal.Proposal {
    return .{
        .kind = kind,
        .rule = try allocator.dupe(u8, rule),
        .file = try allocator.dupe(u8, "sample.ts"),
        .line = line,
        .col = col,
        .message = try allocator.dupe(u8, "synthetic proposal"),
        .confidence = .medium,
        .naming_required = false,
        .safe_to_apply = false,
        .edits = &.{},
        .expected_hash = try allocator.dupe(u8, ""),
    };
}
