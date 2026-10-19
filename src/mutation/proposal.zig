const std = @import("std");
const edits = @import("edits.zig");
const patch = @import("patch.zig");

pub const ProposalKind = enum { guard, predicate, constant, closure, boolean };

pub const Confidence = enum { high, medium, low };

pub const Proposal = struct {
    kind: ProposalKind,
    rule: []const u8,
    file: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
    confidence: Confidence,
    naming_required: bool,
    safe_to_apply: bool,
    edits: []edits.Edit,
    expected_hash: []const u8,

    /// Releases every allocated slice owned by the proposal.
    /// Producers must allocate all string fields and edit replacements with the
    /// same allocator; empty slices are ignored by `Allocator.free`.
    pub fn deinit(self: Proposal, allocator: std.mem.Allocator) void {
        allocator.free(self.rule);
        allocator.free(self.file);
        allocator.free(self.message);
        for (self.edits) |edit| {
            allocator.free(edit.replacement);
        }
        allocator.free(self.edits);
        allocator.free(self.expected_hash);
    }
};

pub const ComposeResult = struct {
    candidate: []u8,
    patch: []u8,
    applied: []usize,
    conflicts: []usize,
};

pub fn kindName(kind: ProposalKind) []const u8 {
    return switch (kind) {
        .guard => "guard",
        .predicate => "predicate",
        .constant => "constant",
        .closure => "closure",
        .boolean => "boolean",
    };
}

/// Renders the unified diff for an applicable proposal. Advisory proposals
/// carry no edits and preview as an empty string.
pub fn patchPreview(
    allocator: std.mem.Allocator,
    source: []const u8,
    p: Proposal,
    filename: []const u8,
) ![]u8 {
    std.debug.assert(p.safe_to_apply or p.edits.len == 0);
    if (!p.safe_to_apply or p.edits.len == 0) {
        return allocator.dupe(u8, "");
    }

    const sorted = try allocator.dupe(edits.Edit, p.edits);
    defer allocator.free(sorted);
    edits.sortEdits(sorted);

    const candidate = try edits.apply(allocator, source, sorted);
    defer allocator.free(candidate);

    return patch.generateDiff(allocator, source, candidate, filename);
}

/// Greedily merges non-overlapping applicable proposals, in the given order,
/// into one candidate. Proposals that overlap anything already accepted are
/// reported in `conflicts`; advisory proposals are skipped.
pub fn compose(
    allocator: std.mem.Allocator,
    source: []const u8,
    proposals: []const Proposal,
    filename: []const u8,
) !ComposeResult {
    var accepted: std.ArrayList(edits.Edit) = .empty;
    defer accepted.deinit(allocator);

    var applied: std.ArrayList(usize) = .empty;
    errdefer applied.deinit(allocator);

    var conflicts: std.ArrayList(usize) = .empty;
    errdefer conflicts.deinit(allocator);

    for (proposals, 0..) |p, i| {
        if (!p.safe_to_apply or p.edits.len == 0) continue;

        if (try overlapsAccepted(allocator, p.edits, accepted.items)) {
            try conflicts.append(allocator, i);
            continue;
        }

        try applied.append(allocator, i);
        try accepted.appendSlice(allocator, p.edits);
    }

    const sorted = try allocator.dupe(edits.Edit, accepted.items);
    defer allocator.free(sorted);
    edits.sortEdits(sorted);

    const candidate = try edits.apply(allocator, source, sorted);
    errdefer allocator.free(candidate);

    const diff = try patch.generateDiff(allocator, source, candidate, filename);
    errdefer allocator.free(diff);

    const applied_slice = try applied.toOwnedSlice(allocator);
    errdefer allocator.free(applied_slice);

    const conflicts_slice = try conflicts.toOwnedSlice(allocator);

    return .{
        .candidate = candidate,
        .patch = diff,
        .applied = applied_slice,
        .conflicts = conflicts_slice,
    };
}

pub fn deinitComposeResult(allocator: std.mem.Allocator, self: *ComposeResult) void {
    allocator.free(self.candidate);
    allocator.free(self.patch);
    allocator.free(self.applied);
    allocator.free(self.conflicts);
}

fn overlapsAccepted(
    allocator: std.mem.Allocator,
    candidate_edits: []const edits.Edit,
    accepted: []const edits.Edit,
) !bool {
    if (accepted.len == 0) return edits.anyOverlap(candidate_edits);

    var scratch: std.ArrayList(edits.Edit) = .empty;
    defer scratch.deinit(allocator);
    try scratch.appendSlice(allocator, accepted);
    try scratch.appendSlice(allocator, candidate_edits);
    return edits.anyOverlap(scratch.items);
}

const TEST_HASH: []const u8 = "0000000000000000000000000000000000000000000000000000000000000000";

fn makeProposal(
    allocator: std.mem.Allocator,
    kind: ProposalKind,
    rule: []const u8,
    file: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
    safe_to_apply: bool,
    proposed_edits: []const edits.Edit,
    expected_hash: []const u8,
) !Proposal {
    const owned_edits = try allocator.alloc(edits.Edit, proposed_edits.len);
    errdefer allocator.free(owned_edits);
    for (proposed_edits, 0..) |edit, i| {
        owned_edits[i] = .{
            .start = edit.start,
            .end = edit.end,
            .replacement = try allocator.dupe(u8, edit.replacement),
        };
    }

    return .{
        .kind = kind,
        .rule = try allocator.dupe(u8, rule),
        .file = try allocator.dupe(u8, file),
        .line = line,
        .col = col,
        .message = try allocator.dupe(u8, message),
        .confidence = .medium,
        .naming_required = false,
        .safe_to_apply = safe_to_apply,
        .edits = owned_edits,
        .expected_hash = try allocator.dupe(u8, expected_hash),
    };
}

test "patchPreview renders unified diff from edits" {
    const allocator = std.testing.allocator;
    const source = "const s = \"A\";\n";
    const at = std.mem.indexOf(u8, source, "\"A\"").?;

    var p = try makeProposal(allocator, .constant, "repeated-literal", "sample.ts", 1, 11, "literal repeated", true, &.{
        .{ .start = @intCast(at), .end = @intCast(at + 3), .replacement = "NAME" },
    }, TEST_HASH);
    defer p.deinit(allocator);

    const preview = try patchPreview(allocator, source, p, "sample.ts");
    defer allocator.free(preview);

    try std.testing.expect(std.mem.indexOf(u8, preview, "-const s = \"A\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "+const s = NAME;") != null);
}

test "patchPreview is empty for advisory proposals" {
    const allocator = std.testing.allocator;
    const source = "const s = \"A\";\n";

    var p = try makeProposal(allocator, .guard, "excessive-nesting", "sample.ts", 1, 1, "advisory", false, &.{}, TEST_HASH);
    defer p.deinit(allocator);

    const preview = try patchPreview(allocator, source, p, "sample.ts");
    defer allocator.free(preview);

    try std.testing.expectEqualStrings("", preview);
}

test "compose merges non-overlapping proposals" {
    const allocator = std.testing.allocator;
    const source = "abcdefgh";

    var p0 = try makeProposal(allocator, .guard, "excessive-nesting", "sample.ts", 1, 1, "first", true, &.{
        .{ .start = 0, .end = 2, .replacement = "XX" },
    }, TEST_HASH);
    defer p0.deinit(allocator);

    var p1 = try makeProposal(allocator, .constant, "repeated-literal", "sample.ts", 2, 1, "second", true, &.{
        .{ .start = 4, .end = 6, .replacement = "YY" },
    }, TEST_HASH);
    defer p1.deinit(allocator);

    var proposals = [_]Proposal{ p0, p1 };
    var result = try compose(allocator, source, &proposals, "sample.ts");
    defer deinitComposeResult(allocator, &result);

    try std.testing.expectEqualStrings("XXcdYYgh", result.candidate);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, result.applied);
    try std.testing.expectEqual(@as(usize, 0), result.conflicts.len);
    try std.testing.expect(result.patch.len > 0);
}

test "compose reports overlapping proposal as conflict" {
    const allocator = std.testing.allocator;
    const source = "abcdef";

    var p0 = try makeProposal(allocator, .guard, "excessive-nesting", "sample.ts", 1, 1, "first", true, &.{
        .{ .start = 0, .end = 3, .replacement = "XXX" },
    }, TEST_HASH);
    defer p0.deinit(allocator);

    var p1 = try makeProposal(allocator, .constant, "repeated-literal", "sample.ts", 1, 2, "second", true, &.{
        .{ .start = 2, .end = 4, .replacement = "Y" },
    }, TEST_HASH);
    defer p1.deinit(allocator);

    var proposals = [_]Proposal{ p0, p1 };
    var result = try compose(allocator, source, &proposals, "sample.ts");
    defer deinitComposeResult(allocator, &result);

    try std.testing.expectEqualStrings("XXXdef", result.candidate);
    try std.testing.expectEqualSlices(usize, &.{0}, result.applied);
    try std.testing.expectEqualSlices(usize, &.{1}, result.conflicts);
}

test "compose with no proposals yields unchanged source and empty patch" {
    const allocator = std.testing.allocator;
    const source = "abcdef";

    var result = try compose(allocator, source, &.{}, "sample.ts");
    defer deinitComposeResult(allocator, &result);

    try std.testing.expectEqualStrings(source, result.candidate);
    try std.testing.expectEqualStrings("", result.patch);
    try std.testing.expectEqual(@as(usize, 0), result.applied.len);
    try std.testing.expectEqual(@as(usize, 0), result.conflicts.len);
}
