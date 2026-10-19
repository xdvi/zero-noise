const std = @import("std");

pub const Edit = struct {
    start: u32,
    end: u32,
    replacement: []const u8,
};

pub const Point = struct {
    line: u32,
    col: u32,
};

/// Applies sorted, non-overlapping byte-range edits to `source`.
/// The caller owns the returned buffer.
pub fn apply(allocator: std.mem.Allocator, source: []const u8, edits: []const Edit) ![]u8 {
    var out_len: usize = source.len;

    for (edits, 0..) |edit, i| {
        if (edit.start > edit.end or edit.end > source.len) return error.OutOfBounds;
        if (i > 0) {
            const prev = edits[i - 1];
            if (edit.start < prev.start) return error.UnsortedEdits;
            if (edit.start < prev.end) return error.OverlappingEdits;
        }
        out_len -= @as(usize, edit.end - edit.start);
        out_len += edit.replacement.len;
    }

    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var cursor: usize = 0;
    var source_pos: usize = 0;
    for (edits) |edit| {
        const start: usize = edit.start;
        const end: usize = edit.end;
        if (start > source_pos) {
            @memcpy(out[cursor .. cursor + (start - source_pos)], source[source_pos..start]);
            cursor += start - source_pos;
        }
        if (edit.replacement.len > 0) {
            @memcpy(out[cursor .. cursor + edit.replacement.len], edit.replacement);
            cursor += edit.replacement.len;
        }
        source_pos = end;
    }
    if (source_pos < source.len) {
        @memcpy(out[cursor .. cursor + (source.len - source_pos)], source[source_pos..]);
    }

    return out;
}

pub fn sortEdits(edits: []Edit) void {
    std.mem.sort(Edit, edits, {}, editLessThan);
}

fn editLessThan(_: void, a: Edit, b: Edit) bool {
    if (a.start == b.start) return a.end < b.end;
    return a.start < b.start;
}

/// Reports whether any two edits cover intersecting byte ranges.
/// Two zero-width insertions at the same offset are ordered, not overlapping.
pub fn anyOverlap(edits: []const Edit) bool {
    for (edits, 0..) |a, i| {
        for (edits[i + 1 ..]) |b| {
            if (rangesOverlap(a, b)) return true;
        }
    }
    return false;
}

fn rangesOverlap(a: Edit, b: Edit) bool {
    return a.start < b.end and b.start < a.end;
}

/// Converts a byte offset into a 1-based line and column.
pub fn offsetToPoint(source: []const u8, offset: usize) Point {
    const clamped = @min(offset, source.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{
        .line = line,
        .col = @intCast(clamped - line_start + 1),
    };
}

test "apply replaces byte ranges and validates bounds" {
    const allocator = std.testing.allocator;

    const out = try apply(allocator, "abcdef", &.{
        .{ .start = 1, .end = 3, .replacement = "XY" },
    });
    defer allocator.free(out);
    try std.testing.expectEqualStrings("aXYdef", out);

    try std.testing.expectError(error.OutOfBounds, apply(allocator, "abc", &.{
        .{ .start = 1, .end = 9, .replacement = "X" },
    }));
}

test "apply rejects overlapping and unsorted edits" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.OverlappingEdits, apply(allocator, "abcdef", &.{
        .{ .start = 1, .end = 4, .replacement = "X" },
        .{ .start = 3, .end = 5, .replacement = "Y" },
    }));

    try std.testing.expectError(error.UnsortedEdits, apply(allocator, "abcdef", &.{
        .{ .start = 3, .end = 4, .replacement = "X" },
        .{ .start = 1, .end = 2, .replacement = "Y" },
    }));
}

test "crlf and missing trailing newline survive apply" {
    const allocator = std.testing.allocator;

    const crlf_out = try apply(allocator, "a\r\nb", &.{
        .{ .start = 3, .end = 4, .replacement = "B" },
    });
    defer allocator.free(crlf_out);
    try std.testing.expectEqualStrings("a\r\nB", crlf_out);

    const no_newline_out = try apply(allocator, "x", &.{
        .{ .start = 0, .end = 1, .replacement = "y" },
    });
    defer allocator.free(no_newline_out);
    try std.testing.expectEqualStrings("y", no_newline_out);
}

test "offsetToPoint counts lines and columns" {
    const source = "ab\ncd";
    const point = offsetToPoint(source, 3);
    try std.testing.expectEqual(@as(u32, 2), point.line);
    try std.testing.expectEqual(@as(u32, 1), point.col);

    const start = offsetToPoint(source, 0);
    try std.testing.expectEqual(@as(u32, 1), start.line);
    try std.testing.expectEqual(@as(u32, 1), start.col);
}

test "sortEdits orders by start then end and anyOverlap detects ranges" {
    var list = [_]Edit{
        .{ .start = 4, .end = 6, .replacement = "c" },
        .{ .start = 0, .end = 2, .replacement = "a" },
        .{ .start = 2, .end = 4, .replacement = "b" },
    };
    sortEdits(&list);
    try std.testing.expectEqual(@as(u32, 0), list[0].start);
    try std.testing.expectEqual(@as(u32, 2), list[1].start);
    try std.testing.expectEqual(@as(u32, 4), list[2].start);

    try std.testing.expect(!anyOverlap(&list));
    try std.testing.expect(anyOverlap(&.{
        .{ .start = 0, .end = 3, .replacement = "" },
        .{ .start = 2, .end = 4, .replacement = "" },
    }));
    try std.testing.expect(anyOverlap(&.{
        .{ .start = 0, .end = 4, .replacement = "" },
        .{ .start = 2, .end = 2, .replacement = "" },
    }));
}
