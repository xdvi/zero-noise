const std = @import("std");
const grammars = @import("../treesitter/grammars.zig");

pub fn getStringArg(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    if (args) |v| {
        if (v == .object) {
            if (v.object.get(key)) |val| {
                if (val == .string) return val.string;
            }
        }
    }
    return null;
}

pub fn getIntArg(args: ?std.json.Value, key: []const u8, default_val: i64) i64 {
    const v = args orelse return default_val;
    if (v != .object) return default_val;
    const val = v.object.get(key) orelse return default_val;
    if (val != .integer) return default_val;
    if (val.integer < 0 or val.integer > std.math.maxInt(u32)) return default_val;
    return val.integer;
}

pub fn getU32Arg(args: ?std.json.Value, key: []const u8, default_val: u32) u32 {
    const raw = getIntArg(args, key, default_val);
    if (raw >= 0 and raw <= std.math.maxInt(u32)) {
        return @intCast(raw);
    }
    return default_val;
}

pub fn getBoolArg(args: ?std.json.Value, key: []const u8, default_val: bool) bool {
    const v = args orelse return default_val;
    if (v != .object) return default_val;
    const val = v.object.get(key) orelse return default_val;
    if (val != .bool) return default_val;
    return val.bool;
}

pub fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    try list.print(allocator, "{f}", .{std.json.fmt(str, .{})});
}

pub fn openAnyFile(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options);
    } else {
        return std.Io.Dir.cwd().openFile(io, path, options);
    }
}

pub fn openAnyDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const clean_path = if (trimmed.len == 0) (if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) "/" else ".") else trimmed;
    if (std.fs.path.isAbsolute(clean_path)) {
        return std.Io.Dir.openDirAbsolute(io, clean_path, options);
    } else {
        return std.Io.Dir.cwd().openDir(io, clean_path, options);
    }
}

pub fn collectSourceFiles(allocator: std.mem.Allocator, root_path: []const u8, files_list: *std.ArrayList([]const u8)) !void {
    const io = std.Options.debug_io;

    if (openAnyDir(io, root_path, .{ .iterate = true })) |*opened_dir| {
        var dir = opened_dir.*;
        defer dir.close(io);

        var walker = dir.walkSelectively(allocator) catch return;
        defer walker.deinit();

        try walkSourceEntries(allocator, io, &walker, root_path, files_list);
        return;
    } else |_| {}

    if (openAnyFile(io, root_path, .{})) |f| {
        f.close(io);
        const lang = grammars.Language.fromPath(root_path);
        if (lang != .unknown) {
            try files_list.append(allocator, try allocator.dupe(u8, root_path));
        }
        return;
    } else |_| {}
}

pub const ToolResult = struct {
    text: []const u8,
    is_error: bool,
    count: usize = 0,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn isIgnoredEntryName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, ".")) return true;
    const ignored = [_][]const u8{ "node_modules", "target", "zig-out", "zig-cache", "bin", "obj" };
    for (ignored) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }
    return false;
}

fn buildSourcePath(allocator: std.mem.Allocator, root_path: []const u8, entry_path: []const u8) ![]u8 {
    const trimmed_root = std.mem.trimEnd(u8, root_path, "/\\");
    if (std.mem.eql(u8, trimmed_root, ".")) {
        return allocator.dupe(u8, entry_path);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_root, entry_path });
}

fn appendSourceFile(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    basename: []const u8,
    entry_path: []const u8,
    files_list: *std.ArrayList([]const u8),
) !void {
    const lang = grammars.Language.fromPath(basename);
    if (lang == .unknown) return;
    const full = try buildSourcePath(allocator, root_path, entry_path);
    try files_list.append(allocator, full);
}

fn walkSourceEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    walker: *std.Io.Dir.SelectiveWalker,
    root_path: []const u8,
    files_list: *std.ArrayList([]const u8),
) !void {
    while (walker.next(io) catch null) |entry| {
        if (isIgnoredEntryName(entry.basename)) continue;
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        try appendSourceFile(allocator, root_path, entry.basename, entry.path, files_list);
    }
}
