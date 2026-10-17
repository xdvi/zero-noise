const std = @import("std");

pub fn applyPatch(allocator: std.mem.Allocator, original: []const u8, patch_content: []const u8) ![]u8 {
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

pub fn generateDiff(
    allocator: std.mem.Allocator,
    original: []const u8,
    candidate: []const u8,
    filename: []const u8,
) ![]u8 {
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
