const std = @import("std");
const builtin = @import("builtin");

pub fn runTestCommandWithTimeout(allocator: std.mem.Allocator, test_cmd: []const u8, timeout_ms: u32) !bool {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", test_cmd }
    else
        &.{ "/bin/sh", "-c", test_cmd };

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
        } },
    }) catch |err| switch (err) {
        error.Timeout => return error.TestTimeout,
        else => return false,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.success();
}
