const std = @import("std");

pub const Database = struct {
    allocator: std.mem.Allocator,
    db_path: []u8,
    in_memory: bool,

    file_cache: std.StringHashMap(FileCacheData),
    refactor_tasks: std.StringHashMap(RefactorTaskData),
    symbol_refs: std.ArrayList(SymbolRefData),

    pub fn open(allocator: std.mem.Allocator, path_z: [*:0]const u8) !Database {
        const path = std.mem.sliceTo(path_z, 0);
        const in_memory = std.mem.eql(u8, path, ":memory:");
        const db = Database{
            .allocator = allocator,
            .db_path = try allocator.dupe(u8, path),
            .in_memory = in_memory,
            .file_cache = std.StringHashMap(FileCacheData).init(allocator),
            .refactor_tasks = std.StringHashMap(RefactorTaskData).init(allocator),
            .symbol_refs = .empty,
        };
        return db;
    }

    pub fn close(self: *Database) void {
        // free file_cache
        var it = self.file_cache.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.sha256);
        }
        self.file_cache.deinit();
        // free refactor_tasks
        var it2 = self.refactor_tasks.iterator();
        while (it2.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.task_id);
            self.allocator.free(e.value_ptr.file);
            self.allocator.free(e.value_ptr.expected_hash);
            self.allocator.free(e.value_ptr.status);
        }
        self.refactor_tasks.deinit();
        // free symbol_refs
        for (self.symbol_refs.items) |r| {
            self.allocator.free(r.symbol);
            self.allocator.free(r.file);
        }
        self.symbol_refs.deinit(self.allocator);
        self.allocator.free(self.db_path);
    }

    pub fn recordFileCache(self: *Database, path: [*:0]const u8, mtime: i64, size: i64, sha256: [*:0]const u8, noise_count: i32, complexity: i32) !void {
        const path_str = std.mem.sliceTo(path, 0);
        const sha_str = std.mem.sliceTo(sha256, 0);
        const key = try self.allocator.dupe(u8, path_str);
        errdefer self.allocator.free(key);
        const val = FileCacheData{
            .path = key,
            .mtime = mtime,
            .size = size,
            .sha256 = try self.allocator.dupe(u8, sha_str),
            .noise_count = noise_count,
            .complexity = complexity,
        };
        try self.file_cache.put(key, val);
    }

    pub fn recordFileCacheSlice(self: *Database, allocator: std.mem.Allocator, path: []const u8, mtime: i64, size: i64, sha256: []const u8, noise_count: i32, complexity: i32) !void {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        const sha_z = try allocator.dupeSentinel(u8, sha256, 0);
        defer allocator.free(sha_z);
        return self.recordFileCache(path_z.ptr, mtime, size, sha_z.ptr, noise_count, complexity);
    }

    pub const FileCacheEntry = struct {
        path: []const u8,
        mtime: i64,
        size: i64,
        sha256: []const u8,
        noise_count: i32,
        complexity: i32,

        pub fn deinit(self: FileCacheEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.sha256);
        }
    };

    pub fn getFileCache(self: Database, allocator: std.mem.Allocator, path: []const u8) !?FileCacheEntry {
        if (self.file_cache.get(path)) |v| {
            return FileCacheEntry{
                .path = try allocator.dupe(u8, v.path),
                .mtime = v.mtime,
                .size = v.size,
                .sha256 = try allocator.dupe(u8, v.sha256),
                .noise_count = v.noise_count,
                .complexity = v.complexity,
            };
        }
        return null;
    }

    pub fn getRefactorTasks(self: *Database) *std.StringHashMap(RefactorTaskData) {
        return &self.refactor_tasks;
    }

    pub fn getSymbolRefs(self: *Database) *std.ArrayList(SymbolRefData) {
        return &self.symbol_refs;
    }
};

const FileCacheData = struct {
    path: []const u8,
    mtime: i64,
    size: i64,
    sha256: []const u8,
    noise_count: i32,
    complexity: i32,
};

pub const RefactorTaskData = struct {
    task_id: []const u8,
    file: []const u8,
    expected_hash: []const u8,
    initial_complexity: i32,
    initial_noise: i32,
    status: []const u8,
    updated_at: i64,
};

pub const SymbolRefData = struct {
    symbol: []const u8,
    file: []const u8,
    line: u32,
    col: u32,
    is_def: bool,
};

pub const DbPaths = struct {
    dir_path: []u8,
    db_path: [:0]u8,

    pub fn deinit(self: DbPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.dir_path);
        allocator.free(self.db_path);
    }
};

fn resolveDbPaths(allocator: std.mem.Allocator, root_path: []const u8) !DbPaths {
    const clean_root = std.mem.trimEnd(u8, root_path, "/\\");
    const dir_path = if (clean_root.len == 0 or std.mem.eql(u8, clean_root, "."))
        try allocator.dupe(u8, ".zero-noise")
    else
        try std.fmt.allocPrint(allocator, "{s}/.zero-noise", .{clean_root});

    const db_path_str = if (clean_root.len == 0 or std.mem.eql(u8, clean_root, "."))
        try allocator.dupe(u8, ".zero-noise/state.db")
    else
        try std.fmt.allocPrint(allocator, "{s}/.zero-noise/state.db", .{clean_root});
    defer allocator.free(db_path_str);

    const db_path = try allocator.dupeSentinel(u8, db_path_str, 0);
    return .{ .dir_path = dir_path, .db_path = db_path };
}

pub fn openProjectDb(allocator: std.mem.Allocator, root_path: []const u8) !Database {
    const paths = try resolveDbPaths(allocator, root_path);
    defer paths.deinit(allocator);

    const io = std.Options.debug_io;
    std.Io.Dir.cwd().createDirPath(io, paths.dir_path) catch {};

    return Database.open(allocator, paths.db_path.ptr);
}

pub fn bootstrap(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !void {
    const paths = try resolveDbPaths(allocator, root_path);
    defer paths.deinit(allocator);

    std.Io.Dir.cwd().createDirPath(io, paths.dir_path) catch {};

    var db = try Database.open(allocator, paths.db_path.ptr);
    db.close();
}