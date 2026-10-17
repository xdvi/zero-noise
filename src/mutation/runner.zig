const std = @import("std");
const builtin = @import("builtin");
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

    pub fn deinit(self: *SafeRefactorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        if (self.error_msg) |err| allocator.free(err);
    }
};

fn checkWorkspaceConfinement(allocator: std.mem.Allocator, filepath: []const u8) !bool {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return false;

    var canonical_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z: [*:0]const u8 = @ptrCast(cwd_ptr);
    const canonical_cwd_ptr = std.c.realpath(cwd_z, &canonical_cwd_buf) orelse cwd_z;
    const cwd = std.mem.sliceTo(canonical_cwd_ptr, 0);

    const resolved = try std.fs.path.resolve(allocator, &.{ cwd, filepath });
    defer allocator.free(resolved);

    var curr_path = try allocator.dupe(u8, resolved);
    defer allocator.free(curr_path);

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const curr_z = try allocator.dupeSentinel(u8, curr_path, 0);
        defer allocator.free(curr_z);

        if (std.c.realpath(curr_z, &real_buf)) |real_ptr| {
            const canonical = std.mem.sliceTo(real_ptr, 0);
            if (std.mem.startsWith(u8, canonical, cwd)) {
                if (canonical.len == cwd.len or canonical[cwd.len] == std.fs.path.sep) {
                    return true;
                }
            }
            return false;
        }

        const parent = std.fs.path.dirname(curr_path) orelse return false;
        if (parent.len == curr_path.len or std.mem.eql(u8, parent, curr_path)) return false;

        const new_curr = try allocator.dupe(u8, parent);
        allocator.free(curr_path);
        curr_path = new_curr;
    }
}

extern "c" fn getpid() c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn time(arg: ?*anyopaque) c_long;

fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentProcessId();
    } else {
        return @intCast(getpid());
    }
}

var rand_counter: u64 = 0;
fn getRandomToken() u64 {
    const now_sec: i64 = @intCast(time(null));
    const seed: u64 = @bitCast(now_sec);
    rand_counter +%= 1;
    var prng = std.Random.DefaultPrng.init(seed +% rand_counter +% (@as(u64, getProcessId()) << 32));
    return prng.random().int(u64);
}

fn getFileMode(filepath_z: [*:0]const u8) ?u32 {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(
            std.posix.AT.FDCWD,
            filepath_z,
            0,
            .{ .MODE = true },
            &stx,
        );
        if (rc == 0) return @as(u32, stx.mode);
        return null;
    }
    return null;
}

fn setFileMode(filepath_z: [*:0]const u8, mode: u32) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.chmod(filepath_z, @intCast(mode));
    } else if (builtin.os.tag.isDarwin()) {
        _ = chmod(filepath_z, @intCast(mode));
    }
}

fn runTestCommandWithTimeout(allocator: std.mem.Allocator, test_cmd: []const u8, timeout_ms: u32) !bool {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", test_cmd }
    else
        &.{ "/bin/sh", "-c", test_cmd };

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
        } },
    }) catch |err| switch (err) {
        error.Timeout => return error.TestTimeout,
        else => return false,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.success();
}

pub fn executeSafeRefactor(
    allocator: std.mem.Allocator,
    options: SafeRefactorOptions,
) !SafeRefactorResult {
    const is_confined = checkWorkspaceConfinement(allocator, options.filepath) catch false;
    if (!is_confined) {
        const err_msg = try std.fmt.allocPrint(allocator, "error: path traversal detected: file is outside workspace: {s}", .{options.filepath});
        return SafeRefactorResult{
            .status = .aborted,
            .diff = try allocator.dupe(u8, ""),
            .error_msg = err_msg,
        };
    }

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

    const candidate = if (options.patch.candidate_content) |c|
        try allocator.dupe(u8, c)
    else if (options.patch.patch_content) |pc|
        try applyPatch(allocator, original_content, pc)
    else if (options.patch.patch_file) |pf| blk: {
        const patch_data = try readFileAlloc(allocator, pf);
        defer allocator.free(patch_data);
        break :blk try applyPatch(allocator, original_content, patch_data);
    } else
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
    const rand_val = getRandomToken();
    const pid = getProcessId();
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

    const orig_mode = getFileMode(target_path_z);

    try writeFile(tmp_path_z, candidate);
    if (orig_mode) |mode| {
        setFileMode(tmp_path_z, mode);
    }

    const syntax_valid = try validateCandidateSyntaxDelta(options.filepath, original_content, candidate);
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

    if (!atomicRename(target_path_z, backup_path_z)) {
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: atomic backup failed"),
        };
    }

    if (!atomicRename(tmp_path_z, target_path_z)) {
        _ = atomicRename(backup_path_z, target_path_z);
        _ = std.c.unlink(tmp_path_z);
        return SafeRefactorResult{
            .status = .rolled_back,
            .diff = diff,
            .error_msg = try allocator.dupe(u8, "error: atomic rename failed"),
        };
    }

    if (options.test_run.test_cmd) |test_cmd| {
        const test_ok = runTestCommandWithTimeout(allocator, test_cmd, options.test_run.timeout_ms) catch |err| switch (err) {
            error.TestTimeout => {
                _ = atomicRename(backup_path_z, target_path_z);
                return SafeRefactorResult{
                    .status = .rolled_back,
                    .diff = diff,
                    .error_msg = try allocator.dupe(u8, "error: tests failed after refactor, rolled back changes (command timed out)"),
                };
            },
        };

        if (!test_ok) {
            _ = atomicRename(backup_path_z, target_path_z);
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

fn atomicRename(src_path_z: [*:0]const u8, dst_path_z: [*:0]const u8) bool {
    if (std.c.rename(src_path_z, dst_path_z) == 0) return true;
    _ = std.c.unlink(dst_path_z);
    return std.c.rename(src_path_z, dst_path_z) == 0;
}

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

extern "c" fn fseek(stream: ?*std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: ?*std.c.FILE) c_long;
extern "c" fn fileno(stream: ?*std.c.FILE) c_int;

fn isDirectory(filepath_z: [*:0]const u8, fd: ?c_int) bool {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        if (fd) |f_desc| {
            if (f_desc >= 0) {
                const rc = std.os.linux.statx(
                    f_desc,
                    "",
                    0x1000,
                    .{ .MODE = true },
                    &stx,
                );
                if (rc == 0) {
                    return std.os.linux.S.ISDIR(stx.mode);
                }
            }
        }
        const rc = std.os.linux.statx(
            std.posix.AT.FDCWD,
            filepath_z,
            0,
            .{ .MODE = true },
            &stx,
        );
        if (rc == 0) {
            return std.os.linux.S.ISDIR(stx.mode);
        }
        return false;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.stat(filepath_z, &st) == 0) {
            return (st.mode & 0o170000) == 0o040000;
        }
        return false;
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, filepath: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, filepath, 0);
    defer allocator.free(path_z);

    if (isDirectory(path_z, null)) return error.IsDirectory;

    const f = std.c.fopen(path_z, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    const fd = fileno(f);
    if (fd >= 0 and isDirectory(path_z, fd)) {
        return error.IsDirectory;
    }

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
        if (read_bytes == 0) {
            return error.FileReadError;
        }
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
    return validateCandidateSyntaxDelta(filepath, "", content);
}

pub fn validateCandidateSyntaxDelta(filepath: []const u8, original: []const u8, candidate: []const u8) !bool {
    const lang = grammars.Language.fromPath(filepath);
    if (lang != .unknown) {
        const ts_lang = lang.getTsLanguage() orelse return false; // fail closed
        var parser = treesitter.Parser.init() catch return false; // fail closed
        defer parser.deinit();
        if (!parser.setLanguage(ts_lang)) return false; // fail closed

        var cand_tree = parser.parseString(candidate) catch return false;
        defer cand_tree.deinit();

        const cand_has_err = cand_tree.rootNode().hasError();
        if (!cand_has_err) return true;

        if (original.len == 0) return false;

        var orig_tree = parser.parseString(original) catch return false;
        defer orig_tree.deinit();

        const orig_has_err = orig_tree.rootNode().hasError();
        if (!orig_has_err) {
            return false;
        }

        const orig_err_count = countSyntaxErrors(orig_tree.rootNode());
        const cand_err_count = countSyntaxErrors(cand_tree.rootNode());
        if (cand_err_count > orig_err_count) {
            return false;
        }
        return true;
    }

    if (checkBalancedBrackets(candidate)) return true;
    if (original.len > 0 and !checkBalancedBrackets(original)) {
        return true;
    }
    return false;
}

fn countSyntaxErrors(node: treesitter.TSNode) usize {
    if (!node.hasError()) return 0;
    var count: usize = 0;
    if (node.isError() or std.mem.eql(u8, node.getType(), "ERROR")) {
        count += 1;
    }
    const children = node.childCount();
    var idx: u32 = 0;
    while (idx < children) : (idx += 1) {
        count += countSyntaxErrors(node.child(idx));
    }
    return count;
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

pub fn applyPatch(allocator: std.mem.Allocator, original: []const u8, patch_content: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, patch_content, "@@ -") == null) {
        return error.InvalidPatch;
    }

    var orig_lines: std.ArrayList([]const u8) = .empty;
    defer orig_lines.deinit(allocator);
    var orig_it = std.mem.splitScalar(u8, original, '\n');
    while (orig_it.next()) |line| {
        try orig_lines.append(allocator, line);
    }

    var result_lines: std.ArrayList([]const u8) = .empty;
    defer result_lines.deinit(allocator);

    var orig_idx: usize = 0;
    var patch_it = std.mem.splitScalar(u8, patch_content, '\n');

    while (patch_it.next()) |pline| {
        if (std.mem.startsWith(u8, pline, "@@ -")) {
            const start_idx = std.mem.indexOf(u8, pline, "-") orelse continue;
            const after_minus = pline[start_idx + 1 ..];
            var end_idx: usize = 0;
            while (end_idx < after_minus.len and after_minus[end_idx] != ',' and after_minus[end_idx] != ' ') : (end_idx += 1) {}
            if (end_idx == 0) continue;
            const old_start = std.fmt.parseInt(usize, after_minus[0..end_idx], 10) catch continue;

            const target_line = if (old_start > 0) old_start - 1 else 0;
            while (orig_idx < target_line and orig_idx < orig_lines.items.len) : (orig_idx += 1) {
                try result_lines.append(allocator, orig_lines.items[orig_idx]);
            }
            continue;
        }

        if (std.mem.startsWith(u8, pline, "--- ") or std.mem.startsWith(u8, pline, "+++ ")) {
            continue;
        }

        if (pline.len > 0 and pline[0] == '+') {
            try result_lines.append(allocator, pline[1..]);
        } else if (pline.len > 0 and pline[0] == '-') {
            if (orig_idx < orig_lines.items.len) {
                orig_idx += 1;
            }
        } else if (pline.len > 0 and pline[0] == ' ') {
            if (orig_idx < orig_lines.items.len) {
                try result_lines.append(allocator, orig_lines.items[orig_idx]);
                orig_idx += 1;
            }
        }
    }

    while (orig_idx < orig_lines.items.len) : (orig_idx += 1) {
        try result_lines.append(allocator, orig_lines.items[orig_idx]);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (result_lines.items, 0..) |l, i| {
        if (i == result_lines.items.len - 1 and l.len == 0) {
            break;
        }
        try out.appendSlice(allocator, l);
        if (i < result_lines.items.len - 1 or (original.len > 0 and original[original.len - 1] == '\n')) {
            try out.append(allocator, '\n');
        }
    }

    return out.toOwnedSlice(allocator);
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

    var suffix_len: usize = 0;
    while (prefix_len + suffix_len < orig_lines.items.len and
        prefix_len + suffix_len < cand_lines.items.len and
        std.mem.eql(u8, orig_lines.items[orig_lines.items.len - 1 - suffix_len], cand_lines.items[cand_lines.items.len - 1 - suffix_len]))
    {
        suffix_len += 1;
    }

    const old_start = prefix_len + 1;
    const new_start = prefix_len + 1;
    const old_count = orig_lines.items.len - prefix_len - suffix_len;
    const new_count = cand_lines.items.len - prefix_len - suffix_len;

    const hunk_hdr = try std.fmt.allocPrint(allocator, "@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });
    defer allocator.free(hunk_hdr);
    try out.appendSlice(allocator, hunk_hdr);

    var o_idx = prefix_len;
    while (o_idx < orig_lines.items.len - suffix_len) : (o_idx += 1) {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, orig_lines.items[o_idx]);
        try out.append(allocator, '\n');
    }

    var c_idx = prefix_len;
    while (c_idx < cand_lines.items.len - suffix_len) : (c_idx += 1) {
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
        .patch = .{ .candidate_content = broken_candidate },
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

    const result = try executeSafeRefactor(allocator, .{
        .filepath = tmp_path,
        .test_run = .{ .test_cmd = "sleep 10", .timeout_ms = 50 },

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
        .patch = .{ .candidate_content = candidate },
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
        .patch = .{ .candidate_content = broken_candidate },
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
    const patch =
        \\--- a/test.ts
        \\+++ b/test.ts
        \\@@ -2,1 +2,1 @@
        \\-    return 1;
        \\+    return 42;
    ;

    const patched = try applyPatch(allocator, original, patch);
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
        .patch = .{ .patch_file = patch_target },
        .fix = true,
    });
    var res = result;
    defer res.deinit(allocator);

    try std.testing.expectEqual(RefactorStatus.verified, res.status);
    const updated = try readFileAlloc(allocator, target);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("function foo() {\n    return 99;\n}\n", updated);
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
    const patch =
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -5 +5 @@
        \\-old5
        \\+new5
    ;
    const result = try applyPatch(allocator, original, patch);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1\n2\n3\n4\nnew5\n6\n", result);
}

test "workspace confinement prevents symlink escape" {
    const allocator = std.testing.allocator;
    const link_path = ".test_symlink_escape";
    _ = std.c.unlink(link_path);
    if (std.c.symlink("/etc", link_path) == 0) {
        defer _ = std.c.unlink(link_path);
        const confined = try checkWorkspaceConfinement(allocator, ".test_symlink_escape/passwd");
        try std.testing.expect(!confined);
    }
}
