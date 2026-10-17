const std = @import("std");
const db_mod = @import("db.zig");
const Database = db_mod.Database;

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
    db: *Database,
    allocator: std.mem.Allocator,
    counter: u64 = 0,

    pub fn init(db: *Database, allocator: std.mem.Allocator) RefactorLedger {
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

        const task_id = try self.allocator.dupe(u8, &hex);

        const status = "pending";
        const task_data = db_mod.RefactorTaskData{
            .task_id = try self.allocator.dupe(u8, task_id),
            .file = try self.allocator.dupe(u8, file),
            .expected_hash = try self.allocator.dupe(u8, expected_hash),
            .initial_complexity = initial_complexity,
            .initial_noise = initial_noise,
            .status = try self.allocator.dupe(u8, status),
            .updated_at = now_sec,
        };
        try self.db.getRefactorTasks().put(try self.allocator.dupe(u8, task_id), task_data);

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
        const tasks = self.db.getRefactorTasks();
        var entry = tasks.getPtr(task_id) orelse return error.TaskNotFound;
        self.allocator.free(entry.status);
        entry.status = try self.allocator.dupe(u8, status);
        entry.updated_at = @intCast(time(null));
    }

    pub fn getTask(
        self: *const RefactorLedger,
        allocator: std.mem.Allocator,
        task_id: []const u8,
    ) !?Task {
        const tasks = self.db.getRefactorTasks();
        const entry = tasks.get(task_id) orelse return null;
        return Task{
            .task_id = try allocator.dupe(u8, entry.task_id),
            .file = try allocator.dupe(u8, entry.file),
            .expected_hash = try allocator.dupe(u8, entry.expected_hash),
            .initial_complexity = entry.initial_complexity,
            .initial_noise = entry.initial_noise,
            .status = try allocator.dupe(u8, entry.status),
            .updated_at = entry.updated_at,
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
        const refs = self.db.getSymbolRefs();
        for (refs.items) |*r| {
            if (std.mem.eql(u8, r.symbol, symbol) and std.mem.eql(u8, r.file, file) and r.line == line and r.col == col) {
                r.is_def = is_def;
                return;
            }
        }
        try refs.append(self.allocator, .{
            .symbol = try self.allocator.dupe(u8, symbol),
            .file = try self.allocator.dupe(u8, file),
            .line = line,
            .col = col,
            .is_def = is_def,
        });
    }

    pub fn getSymbolUsages(
        self: *const RefactorLedger,
        allocator: std.mem.Allocator,
        symbol: []const u8,
    ) ![]SymbolRef {
        const refs = self.db.getSymbolRefs();
        var list: std.ArrayList(SymbolRef) = .empty;
        errdefer {
            for (list.items) |r| {
                allocator.free(r.symbol);
                allocator.free(r.file);
            }
            list.deinit(allocator);
        }
        for (refs.items) |r| {
            if (!std.mem.eql(u8, r.symbol, symbol)) continue;
            try list.append(allocator, .{
                .symbol = try allocator.dupe(u8, r.symbol),
                .file = try allocator.dupe(u8, r.file),
                .line = r.line,
                .col = r.col,
                .is_def = r.is_def,
            });
        }
        return list.toOwnedSlice(allocator);
    }
};