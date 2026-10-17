const std = @import("std");
const db_mod = @import("db.zig");
const Database = db_mod.Database;
const sqlite = db_mod.sqlite;

extern "c" fn time(tloc: ?*anyopaque) c_long;

pub const SymbolRef = struct {
    symbol: []const u8,
    file: []const u8,
    line: u32,
    col: u32,
    is_def: bool,

    pub fn deinit(self: SymbolRef, allocator: std.mem.Allocator) void {
        allocator.free(self.symbol);
        allocator.free(self.file);
    }
};

pub fn freeSymbolRefs(allocator: std.mem.Allocator, refs: []const SymbolRef) void {
    for (refs) |ref| {
        allocator.free(ref.symbol);
        allocator.free(ref.file);
    }
    allocator.free(refs);
}

pub const Task = struct {
    task_id: []const u8,
    file: []const u8,
    expected_hash: []const u8,
    initial_complexity: i32,
    initial_noise: i32,
    status: []const u8,
    updated_at: i64,

    pub fn deinit(self: Task, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.file);
        allocator.free(self.expected_hash);
        allocator.free(self.status);
    }
};

pub fn verifyFileHash(file_path: []const u8, expected_hash: []const u8) !bool {
    var path_buf: [1024]u8 = undefined;
    if (file_path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..file_path.len], file_path);
    path_buf[file_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const f = std.c.fopen(path_z, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    return std.ascii.eqlIgnoreCase(&hex, expected_hash);
}

pub const RefactorLedger = struct {
    db: Database,
    allocator: std.mem.Allocator,
    counter: u64 = 0,

    pub fn init(db: Database, allocator: std.mem.Allocator) RefactorLedger {
        return .{
            .db = db,
            .allocator = allocator,
            .counter = 0,
        };
    }

    pub fn createTask(
        self: *RefactorLedger,
        file: []const u8,
        expected_hash: []const u8,
        initial_complexity: i32,
        initial_noise: i32,
    ) ![]const u8 {
        var rand_bytes: [16]u8 = undefined;
        const now_sec: i64 = @intCast(time(null));
        const seed: u64 = @bitCast(now_sec);
        var prng = std.Random.DefaultPrng.init(seed +% self.counter);
        self.counter +%= 1;
        prng.random().bytes(&rand_bytes);

        rand_bytes[6] = (rand_bytes[6] & 0x0f) | 0x40;
        rand_bytes[8] = (rand_bytes[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(rand_bytes, .lower);

        const task_id = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}-{s}-{s}", .{
            hex[0..8],
            hex[8..12],
            hex[12..16],
            hex[16..20],
            hex[20..32],
        });
        errdefer self.allocator.free(task_id);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql =
            \\INSERT INTO refactor_ledger (task_id, file, expected_hash, initial_complexity, initial_noise, status, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
        ;
        if (sqlite.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null) != sqlite.OK) {
            return error.PrepareFailed;
        }
        defer _ = sqlite.sqlite3_finalize(stmt);

        const status = "pending";
        _ = sqlite.sqlite3_bind_text(stmt, 1, task_id.ptr, @intCast(task_id.len), null);
        _ = sqlite.sqlite3_bind_text(stmt, 2, file.ptr, @intCast(file.len), null);
        _ = sqlite.sqlite3_bind_text(stmt, 3, expected_hash.ptr, @intCast(expected_hash.len), null);
        _ = sqlite.sqlite3_bind_int(stmt, 4, initial_complexity);
        _ = sqlite.sqlite3_bind_int(stmt, 5, initial_noise);
        _ = sqlite.sqlite3_bind_text(stmt, 6, status.ptr, @intCast(status.len), null);
        _ = sqlite.sqlite3_bind_int64(stmt, 7, now_sec);

        if (sqlite.sqlite3_step(stmt) != sqlite.DONE) {
            return error.ExecutionFailed;
        }

        return task_id;
    }

    pub fn verifyStateLock(
        self: *const RefactorLedger,
        file: []const u8,
        expected_hash: []const u8,
    ) !bool {
        _ = self;
        return verifyFileHash(file, expected_hash);
    }

    pub fn updateTaskStatus(
        self: *RefactorLedger,
        task_id: []const u8,
        status: []const u8,
    ) !void {
        const now_sec: i64 = @intCast(time(null));

        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql = "UPDATE refactor_ledger SET status = ?1, updated_at = ?2 WHERE task_id = ?3;";
        if (sqlite.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null) != sqlite.OK) {
            return error.PrepareFailed;
        }
        defer _ = sqlite.sqlite3_finalize(stmt);

        _ = sqlite.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), null);
        _ = sqlite.sqlite3_bind_int64(stmt, 2, now_sec);
        _ = sqlite.sqlite3_bind_text(stmt, 3, task_id.ptr, @intCast(task_id.len), null);

        if (sqlite.sqlite3_step(stmt) != sqlite.DONE) {
            return error.ExecutionFailed;
        }
        if (sqlite.sqlite3_changes(self.db.handle) == 0) {
            return error.TaskNotFound;
        }
    }

    pub fn getTask(
        self: *const RefactorLedger,
        allocator: std.mem.Allocator,
        task_id: []const u8,
    ) !?Task {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql =
            \\SELECT task_id, file, expected_hash, initial_complexity, initial_noise, status, updated_at
            \\FROM refactor_ledger WHERE task_id = ?1;
        ;
        if (sqlite.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null) != sqlite.OK) {
            return error.PrepareFailed;
        }
        defer _ = sqlite.sqlite3_finalize(stmt);

        _ = sqlite.sqlite3_bind_text(stmt, 1, task_id.ptr, @intCast(task_id.len), null);

        const step_rc = sqlite.sqlite3_step(stmt);
        if (step_rc == sqlite.DONE) {
            return null;
        }
        if (step_rc != sqlite.ROW) {
            return error.ExecutionFailed;
        }

        const tid_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse "";
        const tid_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
        const file_ptr = sqlite.sqlite3_column_text(stmt, 1) orelse "";
        const file_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));
        const hash_ptr = sqlite.sqlite3_column_text(stmt, 2) orelse "";
        const hash_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 2));
        const complexity = sqlite.sqlite3_column_int(stmt, 3);
        const noise = sqlite.sqlite3_column_int(stmt, 4);
        const status_ptr = sqlite.sqlite3_column_text(stmt, 5) orelse "";
        const status_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 5));
        const updated_at = sqlite.sqlite3_column_int64(stmt, 6);

        const tid_dup = try allocator.dupe(u8, tid_ptr[0..tid_len]);
        errdefer allocator.free(tid_dup);
        const file_dup = try allocator.dupe(u8, file_ptr[0..file_len]);
        errdefer allocator.free(file_dup);
        const hash_dup = try allocator.dupe(u8, hash_ptr[0..hash_len]);
        errdefer allocator.free(hash_dup);
        const status_dup = try allocator.dupe(u8, status_ptr[0..status_len]);
        errdefer allocator.free(status_dup);

        return Task{
            .task_id = tid_dup,
            .file = file_dup,
            .expected_hash = hash_dup,
            .initial_complexity = complexity,
            .initial_noise = noise,
            .status = status_dup,
            .updated_at = updated_at,
        };
    }

    pub fn recordSymbol(
        self: *RefactorLedger,
        symbol: []const u8,
        file: []const u8,
        line: u32,
        col: u32,
        is_def: bool,
    ) !void {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql =
            \\INSERT INTO symbol_refs (symbol, file, line, col, is_definition)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
            \\ON CONFLICT(symbol, file, line, col) DO UPDATE SET
            \\    is_definition=excluded.is_definition;
        ;
        if (sqlite.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null) != sqlite.OK) {
            return error.PrepareFailed;
        }
        defer _ = sqlite.sqlite3_finalize(stmt);

        _ = sqlite.sqlite3_bind_text(stmt, 1, symbol.ptr, @intCast(symbol.len), null);
        _ = sqlite.sqlite3_bind_text(stmt, 2, file.ptr, @intCast(file.len), null);
        _ = sqlite.sqlite3_bind_int(stmt, 3, @intCast(line));
        _ = sqlite.sqlite3_bind_int(stmt, 4, @intCast(col));
        _ = sqlite.sqlite3_bind_int(stmt, 5, if (is_def) 1 else 0);

        if (sqlite.sqlite3_step(stmt) != sqlite.DONE) {
            return error.ExecutionFailed;
        }
    }

    pub fn getSymbolUsages(
        self: *const RefactorLedger,
        allocator: std.mem.Allocator,
        symbol: []const u8,
    ) ![]SymbolRef {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const sql =
            \\SELECT symbol, file, line, col, is_definition
            \\FROM symbol_refs
            \\WHERE symbol = ?1
            \\ORDER BY file, line, col;
        ;
        if (sqlite.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null) != sqlite.OK) {
            return error.PrepareFailed;
        }
        defer _ = sqlite.sqlite3_finalize(stmt);

        _ = sqlite.sqlite3_bind_text(stmt, 1, symbol.ptr, @intCast(symbol.len), null);

        var list: std.ArrayList(SymbolRef) = .empty;
        errdefer {
            for (list.items) |ref| {
                allocator.free(ref.symbol);
                allocator.free(ref.file);
            }
            list.deinit(allocator);
        }

        while (true) {
            const rc = sqlite.sqlite3_step(stmt);
            if (rc == sqlite.DONE) break;
            if (rc != sqlite.ROW) return error.ExecutionFailed;

            const sym_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse "";
            const sym_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const file_ptr = sqlite.sqlite3_column_text(stmt, 1) orelse "";
            const file_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));
            const line: u32 = @intCast(sqlite.sqlite3_column_int(stmt, 2));
            const col: u32 = @intCast(sqlite.sqlite3_column_int(stmt, 3));
            const is_def: bool = (sqlite.sqlite3_column_int(stmt, 4) != 0);

            const sym_dup = try allocator.dupe(u8, sym_ptr[0..sym_len]);
            errdefer allocator.free(sym_dup);
            const file_dup = try allocator.dupe(u8, file_ptr[0..file_len]);
            errdefer allocator.free(file_dup);

            try list.append(allocator, SymbolRef{
                .symbol = sym_dup,
                .file = file_dup,
                .line = line,
                .col = col,
                .is_def = is_def,
            });
        }

        return list.toOwnedSlice(allocator);
    }
};

test "RefactorLedger task lifecycle and state lock" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:");
    defer db.close();

    var ledger = RefactorLedger.init(db, allocator);

    // Create a temporary file to test state lock verification
    const test_file = "test_state_lock.tmp";
    const f = std.c.fopen(test_file, "wb") orelse return error.CannotOpenFile;
    const content = "function compute() { return 42; }\n";
    _ = std.c.fwrite(content.ptr, 1, content.len, f);
    _ = std.c.fclose(f);
    defer _ = std.c.unlink(test_file);

    // Compute expected sha256 hash
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const valid_hash = std.fmt.bytesToHex(digest, .lower);

    // Verify state lock with matching hash
    const lock_ok = try ledger.verifyStateLock(test_file, &valid_hash);
    try std.testing.expect(lock_ok);

    // Verify state lock with mismatching hash
    const mismatch_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const lock_fail = try ledger.verifyStateLock(test_file, mismatch_hash);
    try std.testing.expect(!lock_fail);

    // Create task
    const task_id = try ledger.createTask(test_file, &valid_hash, 12, 3);
    defer allocator.free(task_id);
    try std.testing.expect(task_id.len > 0);

    // Inspect created task
    const initial_task = (try ledger.getTask(allocator, task_id)) orelse return error.TestExpectedTask;
    defer initial_task.deinit(allocator);
    try std.testing.expectEqualStrings(test_file, initial_task.file);
    try std.testing.expectEqualStrings(&valid_hash, initial_task.expected_hash);
    try std.testing.expectEqual(@as(i32, 12), initial_task.initial_complexity);
    try std.testing.expectEqual(@as(i32, 3), initial_task.initial_noise);
    try std.testing.expectEqualStrings("pending", initial_task.status);

    // Update status to verified
    try ledger.updateTaskStatus(task_id, "verified");
    const verified_task = (try ledger.getTask(allocator, task_id)) orelse return error.TestExpectedTask;
    defer verified_task.deinit(allocator);
    try std.testing.expectEqualStrings("verified", verified_task.status);

    // Update status to rolled_back
    try ledger.updateTaskStatus(task_id, "rolled_back");
    const rolled_back_task = (try ledger.getTask(allocator, task_id)) orelse return error.TestExpectedTask;
    defer rolled_back_task.deinit(allocator);
    try std.testing.expectEqualStrings("rolled_back", rolled_back_task.status);

    // Update nonexistent task should return error.TaskNotFound
    try std.testing.expectError(error.TaskNotFound, ledger.updateTaskStatus("non-existent-task-id", "verified"));
}

test "RefactorLedger symbol references and usages" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:");
    defer db.close();

    var ledger = RefactorLedger.init(db, allocator);

    // Record definitions and usages for a symbol
    try ledger.recordSymbol("handleRequest", "src/server.go", 10, 1, true);
    try ledger.recordSymbol("handleRequest", "src/client.go", 45, 12, false);
    try ledger.recordSymbol("handleRequest", "src/router.go", 88, 5, false);

    // Record an unrelated symbol
    try ledger.recordSymbol("parsePayload", "src/parser.go", 15, 1, true);

    // Query usages for handleRequest
    const usages = try ledger.getSymbolUsages(allocator, "handleRequest");
    defer freeSymbolRefs(allocator, usages);

    try std.testing.expectEqual(@as(usize, 3), usages.len);

    // First entry (client.go) alphabetically
    try std.testing.expectEqualStrings("handleRequest", usages[0].symbol);
    try std.testing.expectEqualStrings("src/client.go", usages[0].file);
    try std.testing.expectEqual(@as(u32, 45), usages[0].line);
    try std.testing.expectEqual(@as(u32, 12), usages[0].col);
    try std.testing.expectEqual(false, usages[0].is_def);

    // Second entry (router.go)
    try std.testing.expectEqualStrings("handleRequest", usages[1].symbol);
    try std.testing.expectEqualStrings("src/router.go", usages[1].file);
    try std.testing.expectEqual(@as(u32, 88), usages[1].line);
    try std.testing.expectEqual(@as(u32, 5), usages[1].col);
    try std.testing.expectEqual(false, usages[1].is_def);

    // Third entry (server.go)
    try std.testing.expectEqualStrings("handleRequest", usages[2].symbol);
    try std.testing.expectEqualStrings("src/server.go", usages[2].file);
    try std.testing.expectEqual(@as(u32, 10), usages[2].line);
    try std.testing.expectEqual(@as(u32, 1), usages[2].col);
    try std.testing.expectEqual(true, usages[2].is_def);

    // Query non-existent symbol returns empty slice
    const empty_usages = try ledger.getSymbolUsages(allocator, "nonExistentSymbol");
    defer freeSymbolRefs(allocator, empty_usages);
    try std.testing.expectEqual(@as(usize, 0), empty_usages.len);

    // Conflict update replaces is_definition
    try ledger.recordSymbol("handleRequest", "src/client.go", 45, 12, true);
    const updated_usages = try ledger.getSymbolUsages(allocator, "handleRequest");
    defer freeSymbolRefs(allocator, updated_usages);
    try std.testing.expectEqual(@as(usize, 3), updated_usages.len);
    try std.testing.expectEqual(true, updated_usages[0].is_def);
}
