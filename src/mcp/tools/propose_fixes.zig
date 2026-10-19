const std = @import("std");
const common = @import("../common.zig");
const deps_mod = @import("../deps.zig");
const grammars = @import("../../treesitter/grammars.zig");
const proposal = @import("../../mutation/proposal.zig");
const propose = @import("../../mutation/propose.zig");

const ToolResult = common.ToolResult;

/// Kinds produced by AST passes; `boolean` comes from the text rewriter and is
/// accepted as an argument but never proposed here.
const ENGINE_KINDS = [_]proposal.ProposalKind{ .guard, .predicate, .constant, .closure };

const KIND_COUNT = std.enums.values(proposal.ProposalKind).len;

pub const ProposeFixesParams = struct {
    path: []const u8 = "",
    kinds: ?[]const u8 = null,
    include_patches: bool = false,
    compose: bool = false,
    page: u32 = 1,
    page_size: u32 = 10,
    root: []const u8 = ".",
    format: []const u8 = "json",
};

pub fn parseProposeFixesArgs(args: ?std.json.Value) ProposeFixesParams {
    return .{
        .path = common.getStringArg(args, "path") orelse "",
        .kinds = common.getStringArg(args, "kinds"),
        .include_patches = common.getBoolArg(args, "include_patches", false),
        .compose = common.getBoolArg(args, "compose", false),
        .page = @max(1, common.getU32Arg(args, "page", 1)),
        .page_size = @max(1, common.getU32Arg(args, "page_size", 10)),
        .root = common.getStringArg(args, "root") orelse ".",
        .format = common.getStringArg(args, "format") orelse "json",
    };
}

const ProposalItem = struct {
    proposal: proposal.Proposal,
    patch: ?[]u8 = null,

    fn deinit(self: ProposalItem, allocator: std.mem.Allocator) void {
        self.proposal.deinit(allocator);
        if (self.patch) |patch_text| allocator.free(patch_text);
    }
};

/// Owns every proposal, limitation, and composed candidate it reports.
pub const ProposalReport = struct {
    path: []const u8,
    items: []ProposalItem,
    limitations: [][]const u8,
    requested: std.EnumSet(proposal.ProposalKind),
    capabilities: std.EnumSet(proposal.ProposalKind),
    totals_by_kind: [KIND_COUNT]usize,
    composed: ?proposal.ComposeResult,
    total: usize,
    page: u32,
    page_size: u32,

    pub fn deinit(self: *ProposalReport, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        for (self.limitations) |limitation| allocator.free(limitation);
        allocator.free(self.limitations);
        if (self.composed) |*composed| proposal.deinitComposeResult(allocator, composed);
    }
};

const KindSelection = struct {
    flags: propose.KindFlags,
    requested: std.EnumSet(proposal.ProposalKind),
};

pub fn executeProposeFixesDirect(
    allocator: std.mem.Allocator,
    params: ProposeFixesParams,
    deps: *const deps_mod.Deps,
) !ToolResult {
    if (params.path.len == 0) {
        return ToolResult{
            .text = try allocator.dupe(u8, "Error: propose_fixes requires a path."),
            .is_error = true,
        };
    }

    var report = try collectProposalReport(allocator, params, deps);
    defer report.deinit(allocator);

    const text = try formatProposalReport(allocator, &report, params.format);
    return ToolResult{ .text = text, .is_error = false, .count = report.total };
}

pub fn executeProposeFixesWithDeps(allocator: std.mem.Allocator, args: ?std.json.Value, deps: *const deps_mod.Deps) !ToolResult {
    return executeProposeFixesDirect(allocator, parseProposeFixesArgs(args), deps);
}

pub fn executeProposeFixes(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeProposeFixesWithDeps(allocator, args, &default);
}

pub fn collectProposalReport(
    allocator: std.mem.Allocator,
    params: ProposeFixesParams,
    deps: *const deps_mod.Deps,
) !ProposalReport {
    var limitations: std.ArrayList([]const u8) = .empty;
    errdefer freeLimitations(allocator, limitations.items);

    const selection = try parseKindSelection(allocator, params.kinds, &limitations);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    try common.collectSourceFiles(allocator, params.path, &files);
    std.mem.sort([]const u8, files.items, {}, lessThanString);

    var items: std.ArrayList(ProposalItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var languages: std.ArrayList(grammars.Language) = .empty;
    defer languages.deinit(allocator);

    for (files.items) |file_path| {
        const lang = grammars.Language.fromPath(file_path);
        if (lang == .unknown) continue;
        if (!containsLanguage(languages.items, lang)) try languages.append(allocator, lang);
        try ingestFile(allocator, deps, file_path, selection.flags, params.include_patches, &items, &limitations);
    }

    for (items.items) |*item| {
        const display = try displayPath(allocator, params.root, item.proposal.file);
        allocator.free(item.proposal.file);
        item.proposal.file = display;
    }

    var capabilities: std.EnumSet(proposal.ProposalKind) = .empty;
    for (ENGINE_KINDS) |kind| {
        var enabled = languages.items.len > 0;
        for (languages.items) |lang| {
            if (propose.capabilityFor(kind, lang) != .enabled) {
                enabled = false;
                break;
            }
        }
        if (enabled) capabilities.insert(kind);
    }

    var totals: [KIND_COUNT]usize = @splat(0);
    for (items.items) |item| totals[kindIndex(item.proposal.kind)] += 1;

    var composed: ?proposal.ComposeResult = null;
    if (params.compose) {
        if (files.items.len == 1) {
            composed = try composeForFile(allocator, deps, files.items[0], items.items);
        } else if (files.items.len > 1) {
            try appendLimitationUnique(allocator, &limitations, "compose requires a single file path; not computed for directories");
        } else {
            try appendLimitationUnique(allocator, &limitations, "compose skipped: path matched no supported source files");
        }
    }

    const total = items.items.len;
    const owned_path = try allocator.dupe(u8, params.path);
    errdefer allocator.free(owned_path);
    const owned_items = try items.toOwnedSlice(allocator);
    errdefer {
        for (owned_items) |item| item.deinit(allocator);
        allocator.free(owned_items);
    }
    const owned_limitations = try limitations.toOwnedSlice(allocator);

    return .{
        .path = owned_path,
        .items = owned_items,
        .limitations = owned_limitations,
        .requested = selection.requested,
        .capabilities = capabilities,
        .totals_by_kind = totals,
        .composed = composed,
        .total = total,
        .page = params.page,
        .page_size = params.page_size,
    };
}

/// Root-relative display path when `path` lives under `root`; otherwise the path as given.
fn displayPath(allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return allocator.dupe(u8, path);
    if (path.len > trimmed.len + 1 and std.mem.startsWith(u8, path, trimmed) and
        (path[trimmed.len] == '/' or path[trimmed.len] == '\\'))
    {
        return allocator.dupe(u8, path[trimmed.len + 1 ..]);
    }
    return allocator.dupe(u8, path);
}

/// Requested kinds never fail the call: `boolean` gets a limitation entry and
/// unknown tokens are recorded and ignored.
fn parseKindSelection(
    allocator: std.mem.Allocator,
    raw: ?[]const u8,
    limitations: *std.ArrayList([]const u8),
) !KindSelection {
    if (raw == null) {
        return .{
            .flags = .{},
            .requested = std.EnumSet(proposal.ProposalKind).initMany(&ENGINE_KINDS),
        };
    }

    var selection = KindSelection{
        .flags = .{ .guard = false, .predicate = false, .constant = false, .closure = false, .boolean = false },
        .requested = .empty,
    };

    var tokens = std.mem.splitScalar(u8, raw.?, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;

        if (std.mem.eql(u8, token, "guard")) {
            selection.flags.guard = true;
            selection.requested.insert(.guard);
        } else if (std.mem.eql(u8, token, "predicate")) {
            selection.flags.predicate = true;
            selection.requested.insert(.predicate);
        } else if (std.mem.eql(u8, token, "constant")) {
            selection.flags.constant = true;
            selection.requested.insert(.constant);
        } else if (std.mem.eql(u8, token, "closure")) {
            selection.flags.closure = true;
            selection.requested.insert(.closure);
        } else if (std.mem.eql(u8, token, "boolean")) {
            try appendLimitationUnique(
                allocator,
                limitations,
                "boolean proposals come from the text rewriter (refactor_helper / safe_refactor fix flow), not propose_fixes",
            );
        } else {
            const message = try std.fmt.allocPrint(allocator, "unknown kinds value: {s}", .{token});
            defer allocator.free(message);
            try appendLimitationUnique(allocator, limitations, message);
        }
    }
    return selection;
}

fn ingestFile(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    file_path: []const u8,
    flags: propose.KindFlags,
    include_patches: bool,
    items: *std.ArrayList(ProposalItem),
    limitations: *std.ArrayList([]const u8),
) !void {
    const lang = grammars.Language.fromPath(file_path);
    if (lang == .unknown) return;

    const content = deps.fs.readFileAlloc(allocator, file_path) catch return;
    defer allocator.free(content);

    var collected = deps.collectProposals(allocator, content, lang, flags) catch return;
    defer {
        allocator.free(collected.proposals);
        for (collected.limitations) |limitation| allocator.free(limitation);
        allocator.free(collected.limitations);
    }

    for (collected.limitations) |limitation| {
        try appendLimitationUnique(allocator, limitations, limitation);
    }

    var consumed: usize = 0;
    errdefer for (collected.proposals[consumed..]) |p| p.deinit(allocator);
    for (collected.proposals) |p| {
        try appendItem(allocator, items, p, file_path, content, include_patches);
        consumed += 1;
    }
}

fn appendItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ProposalItem),
    collected: proposal.Proposal,
    file_path: []const u8,
    source: []const u8,
    include_patches: bool,
) !void {
    var p = collected;
    allocator.free(p.file);
    p.file = try allocator.dupe(u8, file_path);
    errdefer allocator.free(p.file);

    var patch_text: ?[]u8 = null;
    errdefer if (patch_text) |owned| allocator.free(owned);
    if (include_patches) {
        patch_text = try proposal.patchPreview(allocator, source, p, std.fs.path.basename(file_path));
    }

    try items.append(allocator, .{ .proposal = p, .patch = patch_text });
}

fn composeForFile(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    file_path: []const u8,
    items: []const ProposalItem,
) !proposal.ComposeResult {
    const basename = std.fs.path.basename(file_path);

    const content = deps.fs.readFileAlloc(allocator, file_path) catch {
        return proposal.compose(allocator, "", &.{}, basename);
    };
    defer allocator.free(content);

    const proposals = try allocator.alloc(proposal.Proposal, items.len);
    defer allocator.free(proposals);
    for (items, 0..) |item, i| proposals[i] = item.proposal;

    return proposal.compose(allocator, content, proposals, basename);
}

fn freeLimitations(allocator: std.mem.Allocator, limitations: []const []const u8) void {
    for (limitations) |limitation| allocator.free(limitation);
}

fn appendLimitationUnique(
    allocator: std.mem.Allocator,
    limitations: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    for (limitations.items) |existing| {
        if (std.mem.eql(u8, existing, text)) return;
    }
    try limitations.append(allocator, try allocator.dupe(u8, text));
}

fn containsLanguage(languages: []const grammars.Language, lang: grammars.Language) bool {
    for (languages) |existing| {
        if (existing == lang) return true;
    }
    return false;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn kindIndex(kind: proposal.ProposalKind) usize {
    return @backingInt(kind);
}

fn kindCount(report: *const ProposalReport, kind: proposal.ProposalKind) usize {
    return report.totals_by_kind[@backingInt(kind)];
}

fn confidenceName(confidence: proposal.Confidence) []const u8 {
    return switch (confidence) {
        .high => "high",
        .medium => "medium",
        .low => "low",
    };
}

fn boolString(value: bool) []const u8 {
    return if (value) "true" else "false";
}

pub fn formatProposalReport(
    allocator: std.mem.Allocator,
    report: *const ProposalReport,
    format: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, format, "json")) return formatReportJson(allocator, report);
    return formatReportLines(allocator, report, !std.mem.eql(u8, format, "compact"));
}

fn formatReportJson(allocator: std.mem.Allocator, report: *const ProposalReport) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const bounds = pageBounds(report);

    try buf.appendSlice(allocator, "{\"schema\":1,\"proposals\":[");
    for (report.items[bounds.start..bounds.end], 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendProposalJson(allocator, &buf, item);
    }

    try buf.print(allocator, "],\"page\":{d},\"page_size\":{d},\"total\":{d},\"totals_by_kind\":{{", .{
        report.page,
        report.page_size,
        report.total,
    });

    var first = true;
    for (std.enums.values(proposal.ProposalKind)) |kind| {
        const count = kindCount(report, kind);
        if (count == 0) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.print(allocator, "\"{s}\":{d}", .{ proposal.kindName(kind), count });
    }
    try buf.append(allocator, '}');

    try buf.appendSlice(allocator, ",\"limitations\":[");
    for (report.limitations, 0..) |limitation, i| {
        if (i > 0) try buf.append(allocator, ',');
        try common.appendJsonEscaped(&buf, allocator, limitation);
    }
    try buf.appendSlice(allocator, "],\"capabilities\":{");

    first = true;
    for (ENGINE_KINDS) |kind| {
        if (!report.requested.contains(kind)) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.print(allocator, "\"{s}\":{s}", .{
            proposal.kindName(kind),
            boolString(report.capabilities.contains(kind)),
        });
    }
    try buf.append(allocator, '}');

    if (report.composed) |composed| {
        try buf.appendSlice(allocator, ",\"composed\":{\"patch\":");
        try common.appendJsonEscaped(&buf, allocator, composed.patch);
        try buf.appendSlice(allocator, ",\"applied\":[");
        for (composed.applied, 0..) |index, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "{d}", .{index});
        }
        try buf.appendSlice(allocator, "],\"conflicts\":[");
        for (composed.conflicts, 0..) |index, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "{d}", .{index});
        }
        try buf.appendSlice(allocator, "]}");
    }

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn appendProposalJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: ProposalItem,
) !void {
    const p = item.proposal;
    try buf.appendSlice(allocator, "{\"kind\":");
    try common.appendJsonEscaped(buf, allocator, proposal.kindName(p.kind));
    try buf.appendSlice(allocator, ",\"rule\":");
    try common.appendJsonEscaped(buf, allocator, p.rule);
    try buf.appendSlice(allocator, ",\"file\":");
    try common.appendJsonEscaped(buf, allocator, p.file);
    try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{ p.line, p.col });
    try common.appendJsonEscaped(buf, allocator, p.message);
    try buf.print(allocator, ",\"confidence\":\"{s}\",\"naming_required\":{s},\"safe_to_apply\":{s},\"expected_hash\":", .{
        confidenceName(p.confidence),
        boolString(p.naming_required),
        boolString(p.safe_to_apply),
    });
    try common.appendJsonEscaped(buf, allocator, p.expected_hash);
    if (item.patch) |patch_text| {
        try buf.appendSlice(allocator, ",\"patch\":");
        try common.appendJsonEscaped(buf, allocator, patch_text);
    }
    try buf.append(allocator, '}');
}

fn formatReportLines(
    allocator: std.mem.Allocator,
    report: *const ProposalReport,
    with_header: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (with_header) {
        try buf.print(allocator, "Zero-Noise Fix Proposals ({s}): total={d} page={d} page_size={d}\n", .{
            report.path,
            report.total,
            report.page,
            report.page_size,
        });
    }

    const bounds = pageBounds(report);
    for (report.items[bounds.start..bounds.end]) |item| {
        const p = item.proposal;
        try buf.print(allocator, "[FIX] {s}:{d}:{d} {s} {s} naming={s} apply={s}\n", .{
            p.file,
            p.line,
            p.col,
            proposal.kindName(p.kind),
            confidenceName(p.confidence),
            boolString(p.naming_required),
            boolString(p.safe_to_apply),
        });
    }

    if (report.items.len == 0) {
        try buf.appendSlice(allocator, "No fix proposals.\n");
    }
    return buf.toOwnedSlice(allocator);
}

const PageBounds = struct {
    start: usize,
    end: usize,
};

fn pageBounds(report: *const ProposalReport) PageBounds {
    const page_index: u64 = if (report.page > 0) report.page - 1 else 0;
    const raw_start = page_index * report.page_size;
    const start: usize = if (raw_start >= report.total) report.total else @intCast(raw_start);
    const raw_end = @as(u64, start) + report.page_size;
    const end: usize = if (raw_end >= report.total) report.total else @intCast(raw_end);
    return .{ .start = start, .end = end };
}

const GUARD_FIXTURE = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";

const TWO_GUARD_FIXTURE =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    sendEmail(user);
    \\  }
    \\}
    \\function notify(user: User): void {
    \\  if (user.hasPaid) {
    \\    sendInvoice(user);
    \\  }
    \\}
    \\
;

const OVERLAP_FIXTURE =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    log("a");
    \\    log("a");
    \\    log("a");
    \\  }
    \\}
    \\
;

fn writeTestFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    try file.writeStreamingAll(io, content);
    file.close(io);
}

fn deleteTestFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};
}

fn fixtureArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "propose_fixes returns paged proposals with expected_hash for a fixture file" {
    const allocator = std.testing.allocator;
    const path = "tests/test_propose_fixes_guard.ts";
    try writeTestFile(allocator, path, GUARD_FIXTURE);
    defer deleteTestFile(path);

    const args_json = "{\"path\":\"" ++ path ++ "\",\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();

    const default = deps_mod.defaultDeps();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);

    try std.testing.expect(!res.is_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("page").?.integer);
    try std.testing.expectEqual(@as(i64, 10), root.get("page_size").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("totals_by_kind").?.object.get("guard").?.integer);

    const proposals = root.get("proposals").?.array;
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    const first = proposals.items[0].object;
    try std.testing.expectEqualStrings("guard", first.get("kind").?.string);
    try std.testing.expectEqualStrings("excessive-nesting", first.get("rule").?.string);
    try std.testing.expectEqualStrings(path, first.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 2), first.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 3), first.get("column").?.integer);
    try std.testing.expectEqualStrings("medium", first.get("confidence").?.string);
    try std.testing.expectEqual(false, first.get("naming_required").?.bool);
    try std.testing.expectEqual(true, first.get("safe_to_apply").?.bool);
    try std.testing.expectEqual(@as(usize, 64), first.get("expected_hash").?.string.len);
}

test "root is honored for proposal display paths" {
    const allocator = std.testing.allocator;
    const path = "tests/fixtures/dirty/noisy_typescript.ts";
    const args_json = "{\"path\":\"" ++ path ++ "\",\"root\":\"tests/fixtures\",\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();

    const default = deps_mod.defaultDeps();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);
    try std.testing.expect(!res.is_error);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();
    const proposals = parsed.value.object.get("proposals").?.array;
    try std.testing.expect(proposals.items.len > 0);
    try std.testing.expectEqualStrings("dirty/noisy_typescript.ts", proposals.items[0].object.get("file").?.string);
}

test "include_patches false omits patch field" {
    const allocator = std.testing.allocator;
    const path = "tests/test_propose_fixes_no_patch.ts";
    try writeTestFile(allocator, path, GUARD_FIXTURE);
    defer deleteTestFile(path);

    const default = deps_mod.defaultDeps();

    const args_json = "{\"path\":\"" ++ path ++ "\",\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("proposals").?.array.items[0].object.get("patch") == null);

    const patch_args_json = "{\"path\":\"" ++ path ++ "\",\"include_patches\":true,\"format\":\"json\"}";
    var patch_args = try fixtureArgs(allocator, patch_args_json);
    defer patch_args.deinit();
    const patch_res = try executeProposeFixesWithDeps(allocator, patch_args.value, &default);
    defer patch_res.deinit(allocator);
    var patch_parsed = try std.json.parseFromSlice(std.json.Value, allocator, patch_res.text, .{});
    defer patch_parsed.deinit();
    const patch_text = patch_parsed.value.object.get("proposals").?.array.items[0].object.get("patch").?.string;
    try std.testing.expect(patch_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, patch_text, "-  if (user.isActive) {") != null);
}

test "compose true returns composed patch with applied indices" {
    const allocator = std.testing.allocator;
    const path = "tests/test_propose_fixes_compose.ts";
    try writeTestFile(allocator, path, TWO_GUARD_FIXTURE);
    defer deleteTestFile(path);

    const args_json = "{\"path\":\"" ++ path ++ "\",\"compose\":true,\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();

    const default = deps_mod.defaultDeps();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), root.get("total").?.integer);

    const composed = root.get("composed").?.object;
    try std.testing.expectEqual(@as(usize, 2), composed.get("applied").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), composed.get("applied").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 1), composed.get("applied").?.array.items[1].integer);
    try std.testing.expectEqual(@as(usize, 0), composed.get("conflicts").?.array.items.len);
    try std.testing.expect(composed.get("patch").?.string.len > 0);
}

test "compose true reports conflicts for overlapping proposals" {
    const allocator = std.testing.allocator;
    const path = "tests/test_propose_fixes_conflict.ts";
    try writeTestFile(allocator, path, OVERLAP_FIXTURE);
    defer deleteTestFile(path);

    const args_json = "{\"path\":\"" ++ path ++ "\",\"compose\":true,\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();

    const default = deps_mod.defaultDeps();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), root.get("total").?.integer);

    const composed = root.get("composed").?.object;
    try std.testing.expectEqual(@as(usize, 1), composed.get("applied").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), composed.get("applied").?.array.items[0].integer);
    try std.testing.expectEqual(@as(usize, 1), composed.get("conflicts").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), composed.get("conflicts").?.array.items[0].integer);
}

test "directory path aggregates and sorts files deterministically" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const dir = "tests/test_propose_fixes_dir";

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try writeTestFile(allocator, dir ++ "/b.ts", GUARD_FIXTURE);
    try writeTestFile(allocator, dir ++ "/a.ts", GUARD_FIXTURE);

    const args_json = "{\"path\":\"" ++ dir ++ "\",\"page_size\":10,\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();

    const default = deps_mod.defaultDeps();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), root.get("total").?.integer);
    const proposals = root.get("proposals").?.array;
    try std.testing.expectEqual(@as(usize, 2), proposals.items.len);
    try std.testing.expectEqualStrings(dir ++ "/a.ts", proposals.items[0].object.get("file").?.string);
    try std.testing.expectEqualStrings(dir ++ "/b.ts", proposals.items[1].object.get("file").?.string);

    const limitations = root.get("limitations").?.array;
    var compose_missing = false;
    for (limitations.items) |limitation| {
        if (std.mem.indexOf(u8, limitation.string, "compose requires a single file path") != null) compose_missing = true;
    }
    try std.testing.expect(!compose_missing);
}

test "unknown kinds argument is ignored with limitation" {
    const allocator = std.testing.allocator;
    const path = "tests/test_propose_fixes_kinds.ts";
    try writeTestFile(allocator, path, GUARD_FIXTURE);
    defer deleteTestFile(path);

    const default = deps_mod.defaultDeps();

    const args_json = "{\"path\":\"" ++ path ++ "\",\"kinds\":\"banana,guard\",\"format\":\"json\"}";
    var args = try fixtureArgs(allocator, args_json);
    defer args.deinit();
    const res = try executeProposeFixesWithDeps(allocator, args.value, &default);
    defer res.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, res.text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1), root.get("proposals").?.array.items.len);

    var banana_seen = false;
    for (root.get("limitations").?.array.items) |limitation| {
        if (std.mem.indexOf(u8, limitation.string, "banana") != null) banana_seen = true;
    }
    try std.testing.expect(banana_seen);

    const boolean_json = "{\"path\":\"" ++ path ++ "\",\"kinds\":\"boolean\",\"format\":\"json\"}";
    var boolean_args = try fixtureArgs(allocator, boolean_json);
    defer boolean_args.deinit();
    const boolean_res = try executeProposeFixesWithDeps(allocator, boolean_args.value, &default);
    defer boolean_res.deinit(allocator);
    var boolean_parsed = try std.json.parseFromSlice(std.json.Value, allocator, boolean_res.text, .{});
    defer boolean_parsed.deinit();

    const boolean_root = boolean_parsed.value.object;
    try std.testing.expectEqual(@as(usize, 0), boolean_root.get("proposals").?.array.items.len);

    var boolean_seen = false;
    for (boolean_root.get("limitations").?.array.items) |limitation| {
        if (std.mem.indexOf(u8, limitation.string, "boolean proposals come from the text rewriter") != null) {
            boolean_seen = true;
        }
    }
    try std.testing.expect(boolean_seen);
}
