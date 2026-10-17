const std = @import("std");
const builtin = @import("builtin");

extern "c" fn getpid() c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn time(arg: ?*anyopaque) c_long;
extern "c" fn fseek(stream: ?*std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: ?*std.c.FILE) c_long;
extern "c" fn fileno(stream: ?*std.c.FILE) c_int;
extern "c" fn ferror(stream: ?*std.c.FILE) c_int;
extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

pub fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentProcessId();
    } else {
        return @intCast(getpid());
    }
}

var rand_counter: u64 = 0;
pub fn getRandomToken() u64 {
    const now_sec: i64 = @intCast(time(null));
    const seed: u64 = @bitCast(now_sec);
    rand_counter +%= 1;
    var prng = std.Random.DefaultPrng.init(seed +% rand_counter +% (@as(u64, getProcessId()) << 32));
    return prng.random().int(u64);
}

pub fn getFileMode(filepath_z: [*:0]const u8) ?u32 {
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

pub fn setFileMode(filepath_z: [*:0]const u8, mode: u32) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.chmod(filepath_z, @intCast(mode));
    } else if (builtin.os.tag.isDarwin()) {
        _ = chmod(filepath_z, @intCast(mode));
    }
}

pub fn isDirectory(filepath_z: [*:0]const u8, fd: ?c_int) bool {
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

pub fn atomicRename(src_path_z: [*:0]const u8, dst_path_z: [*:0]const u8) bool {
    if (std.c.rename(src_path_z, dst_path_z) == 0) return true;
    return false;
}

pub fn checkWorkspaceConfinement(allocator: std.mem.Allocator, filepath: []const u8) !bool {
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
        while (read_bytes < size) {
            const n = std.c.fread(buf.ptr + read_bytes, 1, size - read_bytes, f);
            if (n == 0) {
                if (ferror(f) != 0) return error.FileReadError;
                break;
            }
            read_bytes += n;
        }
        if (read_bytes != size) {
            return error.FileReadError;
        }
    }

    return buf[0..read_bytes];
}

pub fn writeFile(filepath_z: [*:0]const u8, content: []const u8) !void {
    const f = std.c.fopen(filepath_z, "wb") orelse return error.FileWriteError;
    defer _ = std.c.fclose(f);

    var written_total: usize = 0;
    while (written_total < content.len) {
        const n = std.c.fwrite(content.ptr + written_total, 1, content.len - written_total, f);
        if (n == 0) return error.FileWriteError;
        written_total += n;
    }
    if (fflush(f) != 0) return error.FileWriteError;
}
