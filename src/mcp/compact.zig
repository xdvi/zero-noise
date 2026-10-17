const std = @import("std");

pub fn isCompact(format_opt: ?[]const u8) bool {
    if (format_opt) |fmt| {
        return std.mem.eql(u8, fmt, "compact");
    }
    return false;
}

pub fn formatNoise(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: usize,
    col: usize,
    rule: []const u8,
    details: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "[NOISE] {s}:{d}:{d} [{s}] {s}",
        .{ path, line, col, rule, details },
    );
}

pub fn formatComplexity(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: usize,
    func_name: []const u8,
    score: u32,
    threshold: u32,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "[COMPLEXITY] {s}:{d} {s}: {d} (threshold: {d})",
        .{ path, line, func_name, score, threshold },
    );
}

pub fn formatBlast(
    allocator: std.mem.Allocator,
    symbol: []const u8,
    defs: usize,
    refs: usize,
    files: usize,
    risk: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "[BLAST] {s}: defs={d} refs={d} files={d} risk={s}",
        .{ symbol, defs, refs, files, risk },
    );
}

pub fn formatEvidence(
    allocator: std.mem.Allocator,
    path: []const u8,
    hash: []const u8,
    noise_count: usize,
    complexity: u32,
    blast_risk: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "[EVIDENCE] {s} hash={s} noise={d} complexity={d} risk={s}",
        .{ path, hash, noise_count, complexity, blast_risk },
    );
}

pub fn formatRefactor(
    allocator: std.mem.Allocator,
    path: []const u8,
    status: []const u8,
    hash: []const u8,
    message: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "[REFACTOR] {s} status={s} hash={s} {s}",
        .{ path, status, hash, message },
    );
}

pub fn compactJson(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_string = false;
    var escape = false;

    for (input) |c| {
        processCompactChar(allocator, c, &out, &in_string, &escape);
    }

    return out.toOwnedSlice(allocator);
}

test "compact formatting and isCompact" {
    const allocator = std.testing.allocator;

    try std.testing.expect(isCompact("compact"));
    try std.testing.expect(!isCompact("json"));
    try std.testing.expect(!isCompact(null));

    const noise_str = try formatNoise(allocator, "src/foo.ts", 10, 5, "nesting_depth", "depth=3 > 2");
    defer allocator.free(noise_str);
    try std.testing.expectEqualStrings("[NOISE] src/foo.ts:10:5 [nesting_depth] depth=3 > 2", noise_str);

    const comp_str = try formatComplexity(allocator, "src/bar.rs", 42, "calculate", 18, 15);
    defer allocator.free(comp_str);
    try std.testing.expectEqualStrings("[COMPLEXITY] src/bar.rs:42 calculate: 18 (threshold: 15)", comp_str);

    const blast_str = try formatBlast(allocator, "UserSession", 1, 14, 4, "medium");
    defer allocator.free(blast_str);
    try std.testing.expectEqualStrings("[BLAST] UserSession: defs=1 refs=14 files=4 risk=medium", blast_str);

    const evid_str = try formatEvidence(allocator, "main.go", "a1b2c3", 2, 7, "low");
    defer allocator.free(evid_str);
    try std.testing.expectEqualStrings("[EVIDENCE] main.go hash=a1b2c3 noise=2 complexity=7 risk=low", evid_str);

    const ref_str = try formatRefactor(allocator, "test.py", "verified", "deadbeef", "all tests passed");
    defer allocator.free(ref_str);
    try std.testing.expectEqualStrings("[REFACTOR] test.py status=verified hash=deadbeef all tests passed", ref_str);

    const json_in =
        \\{
        \\  "name": "zero-noise",
        \\  "values": [ 1, 2, "hello world" ]
        \\}
    ;
    const json_out = try compactJson(allocator, json_in);
    defer allocator.free(json_out);
    try std.testing.expectEqualStrings("{\"name\":\"zero-noise\",\"values\":[1,2,\"hello world\"]}", json_out);
}


fn processCompactChar(allocator: std.mem.Allocator, c: u8, out: *std.ArrayList(u8), in_string: *bool, escape: *bool) void {
    if (in_string.*) {
        out.append(allocator, c) catch {};
        if (escape.*) {
            escape.* = false;
        } else if (c == '\\') {
            escape.* = true;
        } else if (c == '"') {
            in_string.* = false;
        }
        return;
    }
    if (c == '"') {
        in_string.* = true;
        out.append(allocator, c) catch {};
    } else if (!std.ascii.isWhitespace(c)) {
        out.append(allocator, c) catch {};
    }
}
