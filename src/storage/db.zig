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
};

test "database init and file cache" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.recordFileCache("/test/file.ts", 12345678, 420, "abc123sha", 0, 5);
}
