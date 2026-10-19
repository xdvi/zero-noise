const std = @import("std");
const builtin = @import("builtin");
const rewriter = @import("rewriter.zig");
const io = @import("io.zig");
const patch = @import("patch.zig");
const syntax = @import("syntax.zig");
const test_runner = @import("test_runner.zig");
const edits = @import("edits.zig");
const grammars = @import("../treesitter/grammars.zig");
const proposal_mod = @import("proposal.zig");
const propose = @import("propose.zig");

pub const readFileAlloc = io.readFileAlloc;
pub const writeFile = io.writeFile;
pub const checkWorkspaceConfinement = io.checkWorkspaceConfinement;
pub const getFileMode = io.getFileMode;
pub const setFileMode = io.setFileMode;
pub const isDirectory = io.isDirectory;
pub const atomicRename = io.atomicRename;
pub const getRandomToken = io.getRandomToken;
pub const getProcessId = io.getProcessId;
pub const applyPatch = patch.applyPatch;
pub const generateDiff = patch.generateDiff;
pub const validateCandidateSyntax = syntax.validateCandidateSyntax;
pub const validateCandidateSyntaxDelta = syntax.validateCandidateSyntaxDelta;
pub const countSyntaxErrors = syntax.countSyntaxErrors;
pub const checkBalancedBrackets = syntax.checkBalancedBrackets;
pub const runTestCommandWithTimeout = test_runner.runTestCommandWithTimeout;

pub const RefactorStatus = enum {
    verified,
    rolled_back,
    aborted,
    dry_run,

    pub fn asString(self: RefactorStatus) []const u8 {
        return switch (self) {
            .verified => "verified",
            .rolled_back => "rolled_back",
            .aborted => "aborted",
            .dry_run => "dry_run",
        };
    }
};

pub const HashLock = struct {
    expected_hash: ?[]const u8 = null,
};

pub const TestRun = struct {
    test_cmd: ?[]const u8 = null,
    timeout_ms: u32 = 60_000,
};

pub const PatchSource = struct {
    candidate_content: ?[]const u8 = null,
    patch_file: ?[]const u8 = null,
    patch_content: ?[]const u8 = null,
    patch_kind: ?[]const u8 = null,
};

/// How the engine learned the patch kind: `verified` when the candidate bytes
/// exactly reproduce one or more engine proposals, `declared` otherwise.
pub const Classification = enum {
    verified,
    declared,

    pub fn asString(self: Classification) []const u8 {
        return switch (self) {
            .verified => "verified",
            .declared => "declared",
        };
    }
};

pub const SafeRefactorOptions = struct {
    filepath: []const u8,
    hash: HashLock = .{},
    test_run: TestRun = .{},
    patch: PatchSource = .{},
    fix: bool = true,
};

pub const SafeRefactorResult = struct {
    status: RefactorStatus,
    diff: []const u8,
    error_msg: ?[]const u8 = null,
    classification: ?Classification = null,

    pub fn deinit(self: *SafeRefactorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        if (self.error_msg) |err| allocator.free(err);
    }
};

/// Every kind accepted on apply: the engine proposal kinds plus `manual` for
/// free-form patches the engine cannot reproduce.
const PATCH_KINDS = [_][]const u8{ "guard", "predicate", "constant", "closure", "boolean", "manual" };

fn isKnownPatchKind(kind: []const u8) bool {
    for (PATCH_KINDS) |known| {
        if (std.mem.eql(u8, kind, known)) return true;
    }
    return false;
}

fn proposalKindFromName(name: []const u8) ?proposal_mod.ProposalKind {
    if (std.mem.eql(u8, name, "guard")) return .guard;
    if (std.mem.eql(u8, name, "predicate")) return .predicate;
    if (std.mem.eql(u8, name, "constant")) return .constant;
    if (std.mem.eql(u8, name, "closure")) return .closure;
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    return null;
}

fn hasPatchSource(p: PatchSource) bool {
    return p.candidate_content != null or p.patch_file != null or p.patch_content != null;
}

fn abortedResult(allocator: std.mem.Allocator, err_msg: []u8) !SafeRefactorResult {
    errdefer allocator.free(err_msg);
    return .{
        .status = .aborted,
        .diff = try allocator.dupe(u8, ""),
        .error_msg = err_msg,
    };
}

/// Applying a supplied patch always declares its kind: absent or unknown
/// values abort before the file is touched.
fn enforcePatchKind(allocator: std.mem.Allocator, patch_source: PatchSource) !?SafeRefactorResult {
    if (!hasPatchSource(patch_source)) return null;

    const kind = patch_source.patch_kind orelse return try abortedResult(
        allocator,
        try allocator.dupe(u8, "error: patch_kind required for patch applications (one of guard|predicate|constant|closure|boolean|manual)"),
    );
    if (!isKnownPatchKind(kind)) {
        return try abortedResult(
            allocator,
            try std.fmt.allocPrint(allocator, "error: unknown patch_kind '{s}' (one of guard|predicate|constant|closure|boolean|manual)", .{kind}),
        );
    }
    return null;
}

const ClassificationOutcome = struct {
    classification: Classification,
    verified_kinds: std.EnumSet(proposal_mod.ProposalKind),
    mismatch_msg: ?[]u8 = null,
};

/// Recomputes the engine proposals for the original source. When the candidate
/// bytes exactly reproduce a single proposal or the greedy composition of
/// several, the true kind set is known and a declared kind outside it aborts.
/// Without an exact match the declared kind stands.
fn classifyPatch(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    source: []const u8,
    candidate: []const u8,
    declared_kind: []const u8,
) !ClassificationOutcome {
    const lang = grammars.Language.fromPath(filepath);
    var collected = try propose.collectProposals(allocator, source, lang, .{});
    defer propose.deinitCollectResult(allocator, &collected);

    var true_kinds: std.EnumSet(proposal_mod.ProposalKind) = .empty;
    var verified = false;

    for (collected.proposals) |p| {
        if (!p.safe_to_apply or p.edits.len == 0) continue;

        const sorted = try allocator.dupe(edits.Edit, p.edits);
        defer allocator.free(sorted);
        edits.sortEdits(sorted);

        const applied = edits.apply(allocator, source, sorted) catch continue;
        defer allocator.free(applied);
        if (std.mem.eql(u8, applied, candidate)) {
            verified = true;
            true_kinds.insert(p.kind);
        }
    }

    const basename = std.fs.path.basename(filepath);
    var composed = try proposal_mod.compose(allocator, source, collected.proposals, basename);
    defer proposal_mod.deinitComposeResult(allocator, &composed);
    if (composed.applied.len > 0 and std.mem.eql(u8, composed.candidate, candidate)) {
        verified = true;
        for (composed.applied) |index| {
            true_kinds.insert(collected.proposals[index].kind);
        }
    }

    if (!verified) {
        return .{ .classification = .declared, .verified_kinds = true_kinds };
    }

    const declared_matches = if (proposalKindFromName(declared_kind)) |declared_engine|
        true_kinds.contains(declared_engine)
    else
        false;
    if (declared_matches) {
        return .{ .classification = .verified, .verified_kinds = true_kinds };
    }

    return .{
        .classification = .verified,
        .verified_kinds = true_kinds,
        .mismatch_msg = try mismatchMessage(allocator, true_kinds, declared_kind),
    };
}

fn mismatchMessage(
    allocator: std.mem.Allocator,
    true_kinds: std.EnumSet(proposal_mod.ProposalKind),
    declared_kind: []const u8,
) ![]u8 {
    var kinds_list: std.ArrayList(u8) = .empty;
    defer kinds_list.deinit(allocator);

    for (std.enums.values(proposal_mod.ProposalKind)) |kind| {
        if (!true_kinds.contains(kind)) continue;
        if (kinds_list.items.len > 0) try kinds_list.append(allocator, ',');
        try kinds_list.appendSlice(allocator, proposal_mod.kindName(kind));
    }

    return std.fmt.allocPrint(
        allocator,
        "classification mismatch: patch reproduces a {s} proposal but declares {s}",
        .{ kinds_list.items, declared_kind },
    );
}

fn requiresTestBracket(declared_kind: []const u8, outcome: ClassificationOutcome) bool {
    if (outcome.classification == .verified) {
        return outcome.verified_kinds.contains(.guard) or outcome.verified_kinds.contains(.predicate);
    }
    return std.mem.eql(u8, declared_kind, "guard") or std.mem.eql(u8, declared_kind, "predicate");
}

pub fn executeSafeRefactor(
    allocator: std.mem.Allocator,
    options: SafeRefactorOptions,
) !SafeRefactorResult {
    const is_confined = io.checkWorkspaceConfinement(allocator, options.filepath) catch false;
    if (!is_confined) {
        const err_msg = try std.fmt.allocPrint(allocator, "error: path traversal detected: file is outside workspace: {s}", .{options.filepath});
        return SafeRefactorResult{
            .status = .aborted,
            .diff = try allocator.dupe(u8, ""),
            .error_msg = err_msg,
        };
    }

    const original_content = io.readFileAlloc(allocator, options.filepath) catch {
        const err_msg = try std.fmt.allocPrint(allocator, "error: target file not found: {s}", .{options.filepath});
        return SafeRefactorResult{
            .status = .aborted,
            .diff = try allocator.dupe(u8, ""),
            .error_msg = err_msg,
        };
    };
    defer allocator.free(original_content);

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(original_content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);

    const actual_hash_buf = std.fmt.bytesToHex(digest, .lower);

    if (options.hash.expected_hash) |exp_hash| {
        const trimmed_expected = std.mem.trim(u8, exp_hash, " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(trimmed_expected, &actual_hash_buf)) {
            const err_msg = try std.fmt.allocPrint(
                allocator,
                "error: state lock failed: file has changed since audit (expected hash {s}, got {s})",
                .{ trimmed_expected, actual_hash_buf },
            );
            return SafeRefactorResult{
                .status = .aborted,
                .diff = try allocator.dupe(u8, ""),
                .error_msg = err_msg,
            };
        }
    }

    if (options.fix) {
        if (try enforcePatchKind(allocator, options.patch)) |aborted| return aborted;
    }

    const candidate = if (options.patch.candidate_content) |c|
        try allocator.dupe(u8, c)
    else if (options.patch.patch_content) |pc|
        try patch.applyPatch(allocator, original_content, pc)
    else if (options.patch.patch_file) |pf| blk: {
        const patch_data = try io.readFileAlloc(allocator, pf);
        defer allocator.free(patch_data);
        break :blk try patch.applyPatch(allocator, original_content, patch_data);
    } else try rewriter.simplify(allocator, original_content);
    defer allocator.free(candidate);

    const basename = std.fs.path.basename(options.filepath);
    const diff = try patch.generateDiff(allocator, original_content, candidate, basename);
    var diff_owned = true;
    defer if (diff_owned) allocator.free(diff);

    if (!options.fix) {
        diff_owned = false;
        return SafeRefactorResult{
            .status = .dry_run,
            .diff = diff,
            .error_msg = null,
        };
    }

    var classification: ?Classification = null;
    if (options.patch.patch_kind) |declared_kind| {
        const outcome = try classifyPatch(allocator, options.filepath, original_content, candidate, declared_kind);
        if (outcome.mismatch_msg) |mismatch| {
            return abortedResult(allocator, mismatch);
        }
        classification = outcome.classification;

        if (requiresTestBracket(declared_kind, outcome) and options.test_run.test_cmd == null) {
            return abortedResult(
                allocator,
                try allocator.dupe(u8, "error: test_cmd required for guard/predicate patches; provide a test command before applying"),
            );
        }
    }

    var result = try applyCandidate(allocator, options, original_content, candidate, diff, basename);
    diff_owned = false;
    result.classification = classification;
    return result;
}

test "state lock aborts on hash mismatch" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_state_lock.ts";
    const content = "function test() { return 1; }\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .hash = .{ .expected_hash = "0000000000000000000000000000000000000000000000000000000000000000" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "state lock failed") != null);
}

test "state lock succeeds on matching hash" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_matching_hash.ts";
    const content = "const ok = valid ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const valid_hash = std.fmt.bytesToHex(digest, .lower);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .hash = .{ .expected_hash = &valid_hash },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings("const ok = valid;\n", read_back);
}

test "dry run does not mutate file" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_dry_run.ts";
    const content = "const x = cond ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .fix = false,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.dry_run, res.status);
    try std.testing.expect(res.diff.len > 0);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(content, read_back);
}

test "syntax validation rolls back broken candidate" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_broken_syntax.ts";
    const content = "function add(a: number, b: number) {\n    return a + b;\n}\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const broken_candidate = "function add(a: number, b: number) {\n    return a + ;\n}\n";

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{ .candidate_content = broken_candidate, .patch_kind = "manual" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.rolled_back, res.status);
    try std.testing.expect(res.error_msg != null);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(content, read_back);
}

test "successful safe refactor with test command" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_success.ts";
    const content = "const ok = valid ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .test_run = .{ .test_cmd = "exit 0" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings("const ok = valid;\n", read_back);
}

test "failing test command rolls back file" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_failing_cmd.ts";
    const content = "const ok = valid ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .test_run = .{ .test_cmd = "exit 1" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.rolled_back, res.status);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(content, read_back);
}

test "workspace confinement prevents path traversal" {
    const allocator = std.testing.allocator;
    const result = try executeSafeRefactor(allocator, .{
        .filepath = "../../etc/passwd",
        .fix = false,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "outside workspace") != null or
        std.mem.indexOf(u8, res.error_msg.?, "path traversal") != null);
}

test "test command timeout rolls back file and kills child" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_timeout.ts";
    const content = "const ok = valid ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const sleep_cmd = if (builtin.os.tag == .windows) "powershell -NoProfile -Command Start-Sleep -Seconds 10" else "sleep 10";
    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .test_run = .{ .test_cmd = sleep_cmd, .timeout_ms = 50 },

        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.rolled_back, res.status);
    try std.testing.expect(res.error_msg != null);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(content, read_back);
}

test "preserves file permissions on refactor and rollback" {
    if (builtin.os.tag != .linux) return;
    const allocator = std.testing.allocator;
    const tmp_path = ".test_perms.ts";
    const content = "const ok = valid ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    _ = std.os.linux.chmod(tmp_path, 0o755);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);

    var stx: std.os.linux.Statx = undefined;
    _ = std.os.linux.statx(std.posix.AT.FDCWD, tmp_path, 0, .{ .MODE = true }, &stx);
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, stx.mode) & 0o777);
}

test "syntax validation delta allows pre-existing syntax errors" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_delta_syntax.ts";
    const content = "const ok = valid ? true : false;\nfunction broken( {\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const candidate = "const ok = valid;\nfunction broken( {\n";

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{ .candidate_content = candidate, .patch_kind = "manual" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
}

test "syntax validation delta rejects candidate introducing NEW syntax errors" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_delta_reject.ts";
    const content = "function broken( {\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const broken_candidate = "function broken( {\nfunction broken2( { ;\n";

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{ .candidate_content = broken_candidate, .patch_kind = "manual" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.rolled_back, res.status);
}

test "generateDiff excludes identical suffix lines" {
    const allocator = std.testing.allocator;
    const original = "prefix1\nprefix2\nmiddle_old\nsuffix1\nsuffix2\n";
    const candidate = "prefix1\nprefix2\nmiddle_new\nsuffix1\nsuffix2\n";

    const diff = try generateDiff(allocator, original, candidate, "test.txt");
    defer allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "-middle_old\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+middle_new\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-suffix1") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+suffix1") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-suffix2") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+suffix2") == null);
    try std.testing.expectEqualStrings(
        "--- a/test.txt\n+++ b/test.txt\n@@ -3,1 +3,1 @@\n-middle_old\n+middle_new\n",
        diff,
    );
}

test "generateDiff handles insertion and deletion with shared suffix" {
    const allocator = std.testing.allocator;
    const original = "a\nb\n";
    const inserted = "a\nmiddle\nb\n";

    const diff_ins = try generateDiff(allocator, original, inserted, "test.txt");
    defer allocator.free(diff_ins);
    try std.testing.expectEqualStrings(
        "--- a/test.txt\n+++ b/test.txt\n@@ -2,0 +2,1 @@\n+middle\n",
        diff_ins,
    );

    const diff_del = try generateDiff(allocator, inserted, original, "test.txt");
    defer allocator.free(diff_del);
    try std.testing.expectEqualStrings(
        "--- a/test.txt\n+++ b/test.txt\n@@ -2,1 +2,0 @@\n-middle\n",
        diff_del,
    );
}

test "safe refactor executes with unique temp and backup paths" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_unique_runner.ts";
    const content = "const ok = valid ? true : false;\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
    // Verify target file was updated
    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings("const ok = valid;\n", read_back);
}

test "cross-platform file permission fallback does not panic or crash" {
    setFileMode(".non_existent_file_test", 0o644);
    _ = getFileMode(".non_existent_file_test");
}

test "applyPatch applies unified diff successfully" {
    const allocator = std.testing.allocator;
    const original = "function hello() {\n    return 1;\n}\n";
    const patch_content =
        \\--- a/test.ts
        \\+++ b/test.ts
        \\@@ -2,1 +2,1 @@
        \\-    return 1;
        \\+    return 42;
    ;

    const patched = try applyPatch(allocator, original, patch_content);
    defer allocator.free(patched);

    try std.testing.expectEqualStrings("function hello() {\n    return 42;\n}\n", patched);
}

test "executeSafeRefactor with patch_file" {
    const allocator = std.testing.allocator;
    const target = ".test_patch_file.ts";
    const patch_target = ".test_patch_file.patch";

    try writeFile(target, "function foo() {\n    return 1;\n}\n");
    defer _ = std.c.unlink(target);

    try writeFile(patch_target,
        \\--- a/.test_patch_file.ts
        \\+++ b/.test_patch_file.ts
        \\@@ -2,1 +2,1 @@
        \\-    return 1;
        \\+    return 99;
    );
    defer _ = std.c.unlink(patch_target);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = target,
        .patch = .{ .patch_file = patch_target, .patch_kind = "manual" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
    const updated = try readFileAlloc(allocator, target);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("function foo() {\n    return 99;\n}\n", updated);
}
const GUARD_FIXTURE = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";

fn fileSha256(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

const EnginePatch = struct {
    candidate: []u8,
    patch_text: []u8,

    fn deinit(self: EnginePatch, allocator: std.mem.Allocator) void {
        allocator.free(self.candidate);
        allocator.free(self.patch_text);
    }
};

fn engineGuardPatch(allocator: std.mem.Allocator, source: []const u8) !EnginePatch {
    var collected = try propose.collectProposals(allocator, source, .typescript, .{});
    defer propose.deinitCollectResult(allocator, &collected);

    var composed = try proposal_mod.compose(allocator, source, collected.proposals, "guard_fixture.ts");
    defer proposal_mod.deinitComposeResult(allocator, &composed);

    return .{
        .candidate = try allocator.dupe(u8, composed.candidate),
        .patch_text = try allocator.dupe(u8, composed.patch),
    };
}

test "apply without patch_kind aborts" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_patch_kind_required.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{ .patch_content = "--- a/x.ts\n+++ b/x.ts\n@@ -1,1 +1,1 @@\n-old\n+new\n" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "patch_kind required for patch applications") != null);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(GUARD_FIXTURE, read_back);
}

test "unknown patch_kind aborts" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_unknown_patch_kind.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{
            .patch_content = "--- a/x.ts\n+++ b/x.ts\n@@ -1,1 +1,1 @@\n-old\n+new\n",
            .patch_kind = "banana",
        },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "unknown patch_kind") != null);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(GUARD_FIXTURE, read_back);
}

test "guard patch without test_cmd aborts untouched" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_guard_needs_tests.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const hash = try fileSha256(allocator, GUARD_FIXTURE);
    defer allocator.free(hash);
    const engine = try engineGuardPatch(allocator, GUARD_FIXTURE);
    defer engine.deinit(allocator);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .hash = .{ .expected_hash = hash },
        .patch = .{ .patch_content = engine.patch_text, .patch_kind = "guard" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "test_cmd required for guard/predicate patches") != null);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(GUARD_FIXTURE, read_back);
}

test "guard patch with passing test_cmd applies" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_guard_with_tests.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const hash = try fileSha256(allocator, GUARD_FIXTURE);
    defer allocator.free(hash);
    const engine = try engineGuardPatch(allocator, GUARD_FIXTURE);
    defer engine.deinit(allocator);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .hash = .{ .expected_hash = hash },
        .test_run = .{ .test_cmd = "zig version" },
        .patch = .{ .patch_content = engine.patch_text, .patch_kind = "guard" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
    try std.testing.expectEqual(Classification.verified, res.classification.?);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(engine.candidate, read_back);
}

test "misclassified guard patch aborts" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_misclassified.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const hash = try fileSha256(allocator, GUARD_FIXTURE);
    defer allocator.free(hash);
    const engine = try engineGuardPatch(allocator, GUARD_FIXTURE);
    defer engine.deinit(allocator);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .hash = .{ .expected_hash = hash },
        .test_run = .{ .test_cmd = "zig version" },
        .patch = .{ .patch_content = engine.patch_text, .patch_kind = "constant" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.startsWith(
        u8,
        res.error_msg.?,
        "classification mismatch: patch reproduces a guard proposal but declares constant",
    ));

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(GUARD_FIXTURE, read_back);
}

test "declared manual candidate applies without engine match" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_declared_manual.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const arbitrary = "function process(user: User): void {\n  sendEmail(user);\n}\n";
    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{ .candidate_content = arbitrary, .patch_kind = "manual" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
    try std.testing.expectEqual(Classification.declared, res.classification.?);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(arbitrary, read_back);
}

test "dry-run previews without patch_kind" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_kindless_dry_run.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const engine = try engineGuardPatch(allocator, GUARD_FIXTURE);
    defer engine.deinit(allocator);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .patch = .{ .patch_content = engine.patch_text },
        .fix = false,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.dry_run, res.status);
    try std.testing.expect(res.diff.len > 0);
    try std.testing.expect(res.classification == null);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(GUARD_FIXTURE, read_back);
}

test "hash mismatch aborts before classification" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_hash_before_classification.ts";
    try writeFile(tmp_path, GUARD_FIXTURE);
    defer _ = std.c.unlink(tmp_path);

    const engine = try engineGuardPatch(allocator, GUARD_FIXTURE);
    defer engine.deinit(allocator);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .hash = .{ .expected_hash = "0000000000000000000000000000000000000000000000000000000000000000" },
        .patch = .{ .patch_content = engine.patch_text, .patch_kind = "guard" },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.aborted, res.status);
    try std.testing.expect(res.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "state lock failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg.?, "test_cmd required") == null);
}

test "readFileAlloc on directory returns error.IsDirectory" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.IsDirectory, readFileAlloc(allocator, "."));
}

test "applyPatch fails safely on patch without hunk header" {
    const allocator = std.testing.allocator;
    const original = "line 1\nline 2\n";
    const invalid_patch = "invalid patch without hunk header\n";
    try std.testing.expectError(error.InvalidPatch, applyPatch(allocator, original, invalid_patch));
}

test "applyPatch supports single-line hunk header without comma" {
    const allocator = std.testing.allocator;
    const original = "1\n2\n3\n4\nold5\n6\n";
    const patch_content =
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -5 +5 @@
        \\-old5
        \\+new5
    ;
    const result = try applyPatch(allocator, original, patch_content);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1\n2\n3\n4\nnew5\n6\n", result);
}

test "workspace confinement prevents symlink escape" {
    if (comptime builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const link_path = ".test_symlink_escape";
    _ = std.c.unlink(link_path);
    if (std.c.symlink("/etc", link_path) == 0) {
        defer _ = std.c.unlink(link_path);
        const confined = try checkWorkspaceConfinement(allocator, ".test_symlink_escape/passwd");
        try std.testing.expect(!confined);
    }
}

fn applyCandidate(
    allocator: std.mem.Allocator,
    options: SafeRefactorOptions,
    original_content: []const u8,
    candidate: []const u8,
    diff: []const u8,
    basename: []const u8,
) !SafeRefactorResult {
    const dirname = std.fs.path.dirname(options.filepath);
    const rand_val = io.getRandomToken();
    const pid = io.getProcessId();
    const tmp_filename = try std.fmt.allocPrint(allocator, ".{s}.{x}_{d}.tmp", .{ basename, rand_val, pid });
    defer allocator.free(tmp_filename);

    const tmp_path = if (dirname) |d|
        try std.fs.path.join(allocator, &.{ d, tmp_filename })
    else
        try allocator.dupe(u8, tmp_filename);
    defer allocator.free(tmp_path);

    const tmp_path_z = try allocator.dupeSentinel(u8, tmp_path, 0);
    defer allocator.free(tmp_path_z);

    const target_path_z = try allocator.dupeSentinel(u8, options.filepath, 0);
    defer allocator.free(target_path_z);

    const orig_mode = io.getFileMode(target_path_z);

    try io.writeFile(tmp_path_z, candidate);
    if (orig_mode) |mode| {
        io.setFileMode(tmp_path_z, mode);
    }

    const syntax_valid = try syntax.validateCandidateSyntaxDelta(options.filepath, original_content, candidate);
    if (!syntax_valid) {
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: syntax error after refactor: AST validation failed"),
        };
    }

    const backup_filename = try std.fmt.allocPrint(allocator, ".{s}.{x}_{d}.orig", .{ basename, rand_val, pid });
    defer allocator.free(backup_filename);

    const backup_path = if (dirname) |d|
        try std.fs.path.join(allocator, &.{ d, backup_filename })
    else
        try allocator.dupe(u8, backup_filename);
    defer allocator.free(backup_path);

    const backup_path_z = try allocator.dupeSentinel(u8, backup_path, 0);
    defer allocator.free(backup_path_z);

    _ = std.c.unlink(backup_path_z);
    if (!io.atomicRename(target_path_z, backup_path_z)) {
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: atomic backup failed"),
        };
    }

    if (!io.atomicRename(tmp_path_z, target_path_z)) {
        _ = io.atomicRename(backup_path_z, target_path_z);
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: atomic rename failed"),
        };
    }

    if (options.test_run.test_cmd) |test_cmd| {
        const test_ok = test_runner.runTestCommandWithTimeout(allocator, test_cmd, options.test_run.timeout_ms) catch |err| switch (err) {
            error.TestTimeout => {
                _ = io.atomicRename(backup_path_z, target_path_z);
                return SafeRefactorResult{
                    .status = .rolled_back,
                    .diff = diff,
                    .error_msg = try allocator.dupe(u8, "error: tests failed after refactor, rolled back changes (command timed out)"),
                };
            },
        };

        if (!test_ok) {
            _ = io.atomicRename(backup_path_z, target_path_z);
            return SafeRefactorResult{
                .status = .rolled_back,
                .diff = diff,
                .error_msg = try allocator.dupe(u8, "error: tests failed after refactor, rolled back changes"),
            };
        }
    }

    _ = std.c.unlink(backup_path_z);

    return SafeRefactorResult{
        .status = .verified,
        .diff = diff,
        .error_msg = null,
    };
}
