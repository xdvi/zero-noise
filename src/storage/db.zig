const std = @import("std");

pub const sqlite = struct {
    pub const OK = 0;
    pub const ROW = 100;
    pub const DONE = 101;

    pub const OPEN_READWRITE = 0x00000002;
    pub const OPEN_CREATE = 0x00000004;

    pub const sqlite3 = anyopaque;
    pub const sqlite3_stmt = anyopaque;

    pub extern "c" fn sqlite3_libversion() [*:0]const u8;
    pub extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
    pub extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
    pub extern "c" fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
    pub extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*[*:0]const u8) c_int;
    pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
    pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
    pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
    pub extern "c" fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
    pub extern "c" fn sqlite3_column_int(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
    pub extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
    pub extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, val: [*]const u8, len: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
    pub extern "c" fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, idx: c_int, val: c_int) c_int;
    pub extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, val: i64) c_int;
    pub extern "c" fn sqlite3_changes(db: ?*sqlite3) c_int;
    pub extern "c" fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
    pub extern "c" fn sqlite3_free(ptr: ?*anyopaque) void;
};

pub const Database = struct {
    handle: *sqlite.sqlite3,

    pub fn open(path_z: [*:0]const u8) !Database {
        var db_ptr: ?*sqlite.sqlite3 = null;
        const flags = sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE;
        const rc = sqlite.sqlite3_open_v2(path_z, &db_ptr, flags, null);
        if (rc != sqlite.OK or db_ptr == null) {
            return error.DatabaseOpenFailed;
        }

        const db = Database{ .handle = db_ptr.? };
        try db.initPragmas();
        try db.initSchema();
        return db;
    }

    pub fn close(self: *Database) void {
        _ = sqlite.sqlite3_close(self.handle);
    }

    pub fn exec(self: Database, sql: [*:0]const u8) !void {
        var err_msg: ?[*:0]u8 = null;
        const rc = sqlite.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != sqlite.OK) {
            if (err_msg) |msg| {
                sqlite.sqlite3_free(msg);
            }
            return error.QueryFailed;
        }
    }

    fn initPragmas(self: Database) !void {
        try self.exec("PRAGMA journal_mode = WAL;");
        try self.exec("PRAGMA synchronous = NORMAL;");
        try self.exec("PRAGMA busy_timeout = 5000;");
    }

    fn initSchema(self: Database) !void {
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS file_cache (
            \\    path TEXT PRIMARY KEY,
            \\    mtime INTEGER NOT NULL,
            \\    size INTEGER NOT NULL,
            \\    sha256 TEXT NOT NULL,
            \\    noise_count INTEGER NOT NULL,
            \\    complexity INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS symbol_refs (
            \\    symbol TEXT NOT NULL,
            \\    file TEXT NOT NULL,
            \\    line INTEGER NOT NULL,
            \\    col INTEGER NOT NULL,
            \\    is_definition INTEGER NOT NULL,
            \\    PRIMARY KEY (symbol, file, line, col)
            \\);
            \\CREATE TABLE IF NOT EXISTS refactor_ledger (
            \\    task_id TEXT PRIMARY KEY,
            \\    file TEXT NOT NULL,
            \\    expected_hash TEXT NOT NULL,
            \\    initial_complexity INTEGER NOT NULL,
            \\    initial_noise INTEGER NOT NULL,
            \\    status TEXT NOT NULL,
            \\    updated_at INTEGER NOT NULL
            \\);
        );
    }

    pub fn recordFileCache(
        self: Database,
        path: [*:0]const u8,
        mtime: i64,
        size: i64,
        sha256: [*:0]const u8,
        noise_count: i32,
        complexity: i32,
    ) !void {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql =
            \\INSERT INTO file_cache (path, mtime, size, sha256, noise_count, complexity)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(path) DO UPDATE SET
            \\    mtime=excluded.mtime,
            \\    size=excluded.size,
            \\    sha256=excluded.sha256,
            \\    noise_count=excluded.noise_count,
            \\    complexity=excluded.complexity;
        ;
        if (sqlite.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != sqlite.OK) return error.PrepareFailed;
        defer _ = sqlite.sqlite3_finalize(stmt);

        _ = sqlite.sqlite3_bind_text(stmt, 1, path, -1, null);
        _ = sqlite.sqlite3_bind_int64(stmt, 2, mtime);
        _ = sqlite.sqlite3_bind_int64(stmt, 3, size);
        _ = sqlite.sqlite3_bind_text(stmt, 4, sha256, -1, null);
        _ = sqlite.sqlite3_bind_int(stmt, 5, noise_count);
        _ = sqlite.sqlite3_bind_int(stmt, 6, complexity);

        if (sqlite.sqlite3_step(stmt) != sqlite.DONE) return error.ExecutionFailed;
    }

    pub fn recordFileCacheSlice(
        self: Database,
        allocator: std.mem.Allocator,
        path: []const u8,
        mtime: i64,
        size: i64,
        sha256: []const u8,
        noise_count: i32,
        complexity: i32,
    ) !void {
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

    pub fn getFileCache(
        self: Database,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?FileCacheEntry {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql = "SELECT path, mtime, size, sha256, noise_count, complexity FROM file_cache WHERE path = ?1;";
        if (sqlite.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != sqlite.OK) return error.PrepareFailed;
        defer _ = sqlite.sqlite3_finalize(stmt);

        _ = sqlite.sqlite3_bind_text(stmt, 1, path.ptr, @intCast(path.len), null);

        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.DONE) return null;
        if (rc != sqlite.ROW) return error.ExecutionFailed;

        const path_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse "";
        const path_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
        const mtime = sqlite.sqlite3_column_int64(stmt, 1);
        const size = sqlite.sqlite3_column_int64(stmt, 2);
        const sha_ptr = sqlite.sqlite3_column_text(stmt, 3) orelse "";
        const sha_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 3));
        const noise_count = sqlite.sqlite3_column_int(stmt, 4);
        const complexity = sqlite.sqlite3_column_int(stmt, 5);

        const path_dup = try allocator.dupe(u8, path_ptr[0..path_len]);
        errdefer allocator.free(path_dup);
        const sha_dup = try allocator.dupe(u8, sha_ptr[0..sha_len]);
        errdefer allocator.free(sha_dup);

        return FileCacheEntry{
            .path = path_dup,
            .mtime = mtime,
            .size = size,
            .sha256 = sha_dup,
            .noise_count = noise_count,
            .complexity = complexity,
        };
    }
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

    return Database.open(paths.db_path.ptr);
}

test "database init and file cache" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:");
    defer db.close();

    try db.recordFileCache("/test/file.ts", 12345678, 420, "abc123sha", 0, 5);

    try db.recordFileCacheSlice(allocator, "/test/file2.ts", 87654321, 512, "fedcba987", 2, 7);
    const entry = (try db.getFileCache(allocator, "/test/file2.ts")) orelse return error.TestExpectedEntry;
    defer entry.deinit(allocator);

    try std.testing.expectEqualStrings("/test/file2.ts", entry.path);
    try std.testing.expectEqual(@as(i64, 87654321), entry.mtime);
    try std.testing.expectEqual(@as(i64, 512), entry.size);
    try std.testing.expectEqualStrings("fedcba987", entry.sha256);
    try std.testing.expectEqual(@as(i32, 2), entry.noise_count);
    try std.testing.expectEqual(@as(i32, 7), entry.complexity);

    const missing = try db.getFileCache(allocator, "/nonexistent.ts");
    try std.testing.expect(missing == null);
}

pub fn bootstrap(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !void {
    const paths = try resolveDbPaths(allocator, root_path);
    defer paths.deinit(allocator);

    std.Io.Dir.cwd().createDirPath(io, paths.dir_path) catch {};

    var db = try Database.open(paths.db_path.ptr);
    db.close();
}

test "bootstrap initializes directory and database" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const test_dir = "tests/.test_bootstrap_env";

    // Clean up if existed
    _ = std.Io.Dir.cwd().deleteFile(io, "tests/.test_bootstrap_env/.zero-noise/state.db") catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, "tests/.test_bootstrap_env/.zero-noise/state.db-wal") catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, "tests/.test_bootstrap_env/.zero-noise/state.db-shm") catch {};

    try bootstrap(allocator, io, test_dir);
    defer {
        _ = std.Io.Dir.cwd().deleteFile(io, "tests/.test_bootstrap_env/.zero-noise/state.db") catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, "tests/.test_bootstrap_env/.zero-noise/state.db-wal") catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, "tests/.test_bootstrap_env/.zero-noise/state.db-shm") catch {};
    }

    // Verify database file exists and can be opened
    var db = try Database.open("tests/.test_bootstrap_env/.zero-noise/state.db");
    defer db.close();

    // Idempotent call - second bootstrap shouldn't fail
    try bootstrap(allocator, io, test_dir);
}

test "database exec error handles memory safely" {
    var db = try Database.open(":memory:");
    defer db.close();

    const err = db.exec("INVALID SQL SYNTAX HERE;");
    try std.testing.expectError(error.QueryFailed, err);
}
