const std = @import("std");
const rewriter = @import("rewriter.zig");
const treesitter = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");

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

pub const SafeRefactorOptions = struct {
    filepath: []const u8,
    expected_hash: ?[]const u8 = null,
    test_cmd: ?[]const u8 = null,
    fix: bool = true,
    candidate_content: ?[]const u8 = null,
    timeout_ms: u32 = 60_000,
};

pub const SafeRefactorResult = struct {
    status: RefactorStatus,
    diff: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn deinit(self: *SafeRefactorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        if (self.error_msg) |err| allocator.free(err);
    }
};

pub fn executeSafeRefactor(
    allocator: std.mem.Allocator,
    options: SafeRefactorOptions,
) !SafeRefactorResult {
    const original_content = readFileAlloc(allocator, options.filepath) catch {
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

    if (options.expected_hash) |exp_hash| {
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

    const candidate = if (options.candidate_content) |c|
        try allocator.dupe(u8, c)
    else
        try rewriter.simplify(allocator, original_content);
    defer allocator.free(candidate);

    const basename = std.fs.path.basename(options.filepath);
    const diff = try generateDiff(allocator, original_content, candidate, basename);
    errdefer allocator.free(diff);

    if (!options.fix) {
        return SafeRefactorResult{
            .status = .dry_run,
            .diff = diff,
            .error_msg = null,
        };
    }

    if (std.mem.eql(u8, original_content, candidate)) {
        return SafeRefactorResult{
            .status = .verified,
            .diff = diff,
            .error_msg = null,
        };
    }

    const dirname = std.fs.path.dirname(options.filepath);
    const tmp_filename = try std.fmt.allocPrint(allocator, ".{s}.tmp", .{basename});
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

    try writeFile(tmp_path_z, candidate);

    const syntax_valid = try validateCandidateSyntax(options.filepath, candidate);
    if (!syntax_valid) {
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: syntax error after refactor: AST validation failed"),
        };
    }

    if (options.test_cmd) |test_cmd| {
        if (!atomicRename(tmp_path_z, target_path_z)) {
            _ = std.c.unlink(tmp_path_z);
            return SafeRefactorResult{
                .status = .rolled_back,
                .diff = diff,
                .error_msg = try allocator.dupe(u8, "error: atomic rename failed"),
            };
        }

        const test_cmd_z = try allocator.dupeSentinel(u8, test_cmd, 0);
        defer allocator.free(test_cmd_z);

        const test_status = system(test_cmd_z);
        if (test_status != 0) {
            try writeFile(target_path_z, original_content);
            return SafeRefactorResult{
                .status = .rolled_back,
                .diff = diff,
                .error_msg = try allocator.dupe(u8, "error: tests failed after refactor, rolled back changes"),
            };
        }

        return SafeRefactorResult{
            .status = .verified,
            .diff = diff,
            .error_msg = null,
        };
    }

    if (!atomicRename(tmp_path_z, target_path_z)) {
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: atomic rename failed"),
        };
    }

    return SafeRefactorResult{
        .status = .verified,
        .diff = diff,
        .error_msg = null,
    };
}

fn atomicRename(src_path_z: [*:0]const u8, dst_path_z: [*:0]const u8) bool {
    if (std.c.rename(src_path_z, dst_path_z) == 0) return true;
    _ = std.c.unlink(dst_path_z);
    return std.c.rename(src_path_z, dst_path_z) == 0;
}

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

extern "c" fn fseek(stream: ?*std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: ?*std.c.FILE) c_long;
extern "c" fn system(command: [*:0]const u8) c_int;

pub fn readFileAlloc(allocator: std.mem.Allocator, filepath: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, filepath, 0);
    defer allocator.free(path_z);

    const f = std.c.fopen(path_z, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    _ = fseek(f, 0, SEEK_END);
    const size_long = ftell(f);
    _ = fseek(f, 0, SEEK_SET);

    if (size_long < 0) return error.FileReadError;
    const size: usize = @intCast(size_long);

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    var read_bytes: usize = 0;
    if (size > 0) {
        read_bytes = std.c.fread(buf.ptr, 1, size, f);
    }

    return buf[0..read_bytes];
}

fn writeFile(filepath_z: [*:0]const u8, content: []const u8) !void {
    const f = std.c.fopen(filepath_z, "wb") orelse return error.FileWriteError;
    defer _ = std.c.fclose(f);

    if (content.len > 0) {
        const written = std.c.fwrite(content.ptr, 1, content.len, f);
        if (written != content.len) return error.FileWriteError;
    }
}

pub fn validateCandidateSyntax(filepath: []const u8, content: []const u8) !bool {
    const lang = grammars.Language.fromPath(filepath);
    if (lang != .unknown) {
        if (lang.getTsLanguage()) |ts_lang| {
            var parser = treesitter.Parser.init() catch return true;
            defer parser.deinit();
            if (!parser.setLanguage(ts_lang)) return true;

            var tree = parser.parseString(content) catch return false;
            defer tree.deinit();

            const root = tree.rootNode();
            if (root.hasError()) return false;
            return true;
        }
    }

    return checkBalancedBrackets(content);
}

fn checkBalancedBrackets(content: []const u8) bool {
    var stack: [1024]u8 = undefined;
    var top: usize = 0;

    var i: usize = 0;
    while (i < content.len) {
        const ch = content[i];

        if (ch == '"' or ch == '\'') {
            i += 1;
            while (i < content.len and content[i] != ch) {
                if (content[i] == '\\') i += 1;
                i += 1;
            }
            if (i < content.len) i += 1;
            continue;
        }

        if (ch == '/' and i + 1 < content.len and content[i + 1] == '/') {
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            continue;
        }

        if (ch == '(' or ch == '[' or ch == '{') {
            if (top >= stack.len) return false;
            stack[top] = ch;
            top += 1;
        } else if (ch == ')' or ch == ']' or ch == '}') {
            if (top == 0) return false;
            const expected: u8 = switch (ch) {
                ')' => '(',
                ']' => '[',
                '}' => '{',
                else => 0,
            };
            top -= 1;
            if (stack[top] != expected) return false;
        }

        i += 1;
    }

    return top == 0;
}

fn generateDiff(
    allocator: std.mem.Allocator,
    original: []const u8,
    candidate: []const u8,
    filename: []const u8,
) ![]const u8 {
    if (std.mem.eql(u8, original, candidate)) {
        return allocator.dupe(u8, "");
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "--- a/{s}\n+++ b/{s}\n", .{ filename, filename });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    var orig_it = std.mem.splitScalar(u8, original, '\n');
    var cand_it = std.mem.splitScalar(u8, candidate, '\n');

    var orig_lines: std.ArrayList([]const u8) = .empty;
    defer orig_lines.deinit(allocator);
    while (orig_it.next()) |line| {
        try orig_lines.append(allocator, line);
    }

    var cand_lines: std.ArrayList([]const u8) = .empty;
    defer cand_lines.deinit(allocator);
    while (cand_it.next()) |line| {
        try cand_lines.append(allocator, line);
    }

    var prefix_len: usize = 0;
    while (prefix_len < orig_lines.items.len and prefix_len < cand_lines.items.len and
        std.mem.eql(u8, orig_lines.items[prefix_len], cand_lines.items[prefix_len]))
    {
        prefix_len += 1;
    }

    const old_start = prefix_len + 1;
    const new_start = prefix_len + 1;
    const old_count = orig_lines.items.len - prefix_len;
    const new_count = cand_lines.items.len - prefix_len;

    const hunk_hdr = try std.fmt.allocPrint(allocator, "@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });
    defer allocator.free(hunk_hdr);
    try out.appendSlice(allocator, hunk_hdr);

    var o_idx = prefix_len;
    while (o_idx < orig_lines.items.len) : (o_idx += 1) {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, orig_lines.items[o_idx]);
        try out.append(allocator, '\n');
    }

    var c_idx = prefix_len;
    while (c_idx < cand_lines.items.len) : (c_idx += 1) {
        try out.append(allocator, '+');
        try out.appendSlice(allocator, cand_lines.items[c_idx]);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

test "state lock aborts on hash mismatch" {
    const allocator = std.testing.allocator;
    const tmp_path = ".test_state_lock.ts";
    const content = "function test() { return 1; }\n";
    try writeFile(tmp_path, content);
    defer _ = std.c.unlink(tmp_path);

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .expected_hash = "0000000000000000000000000000000000000000000000000000000000000000",
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
        .expected_hash = &valid_hash,
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
        .candidate_content = broken_candidate,
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
        .test_cmd = "exit 0",
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
        .test_cmd = "exit 1",
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.rolled_back, res.status);

    const read_back = try readFileAlloc(allocator, tmp_path);
    defer allocator.free(read_back);
    try std.testing.expectEqualStrings(content, read_back);
}
