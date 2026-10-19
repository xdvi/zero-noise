//! Benchmark harness: runs zero-noise scenarios as child processes and reports
//! wall time, CPU time, peak RSS, page faults and context switches per run.
const std = @import("std");

const c = struct {
    const Timeval = extern struct { sec: c_long, usec: c_long };
    const Rusage = extern struct {
        utime: Timeval,
        stime: Timeval,
        maxrss: c_long,
        ixrss: c_long,
        idrss: c_long,
        isrss: c_long,
        minflt: c_long,
        majflt: c_long,
        nswap: c_long,
        inblock: c_long,
        oublock: c_long,
        msgsnd: c_long,
        msgrcv: c_long,
        nsignals: c_long,
        nvcsw: c_long,
        nivcsw: c_long,
    };
    const Timespec = extern struct { sec: c_long, nsec: c_long };
    const CLOCK_MONOTONIC = 1;
    const O_WRONLY = 1;

    extern "c" fn fork() c_int;
    extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn wait4(pid: c_int, status: *c_int, options: c_int, ru: *Rusage) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn dup2(old: c_int, new: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
    extern "c" fn fwrite(buf: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
    extern "c" fn fclose(f: *anyopaque) c_int;
};

const Scenario = struct {
    name: []const u8,
    args: []const []const u8,
};

const scenarios = [_]Scenario{
    .{ .name = "audit", .args = &.{ "audit", "src" } },
    .{ .name = "audit-json", .args = &.{ "audit", "src", "--format=json" } },
    .{ .name = "complexity", .args = &.{ "complexity", "src", "--threshold=100" } },
    .{ .name = "blast", .args = &.{ "blast", "executeSafeRefactor", "--root=src" } },
    .{ .name = "plan-dirty", .args = &.{ "plan", "tests/fixtures/dirty", "--format=json" } },
    .{ .name = "plan-compose", .args = &.{ "plan", "tests/fixtures/dirty/noisy_typescript.ts", "--compose" } },
    .{ .name = "startup", .args = &.{"version"} },
};

const Sample = struct {
    wall_us: f64,
    user_us: f64,
    sys_us: f64,
    maxrss_kb: f64,
    minflt: f64,
    majflt: f64,
    vcsw: f64,
    ivcsw: f64,
    inblock: f64,
    exit_code: u8,
};

const Metric = enum {
    wall_us,
    cpu_us,
    cpu_pct,
    maxrss_kb,
    minflt,
    majflt,
    ctx_switches,
    inblock,

    fn label(self: Metric) []const u8 {
        return switch (self) {
            .wall_us => "wall_us",
            .cpu_us => "cpu_us",
            .cpu_pct => "cpu_pct",
            .maxrss_kb => "maxrss_kb",
            .minflt => "minflt",
            .majflt => "majflt",
            .ctx_switches => "ctx_switches",
            .inblock => "inblock",
        };
    }

    fn of(self: Metric, s: Sample) f64 {
        const cpu = s.user_us + s.sys_us;
        return switch (self) {
            .wall_us => s.wall_us,
            .cpu_us => cpu,
            .cpu_pct => if (s.wall_us > 0) cpu / s.wall_us * 100.0 else 0,
            .maxrss_kb => s.maxrss_kb,
            .minflt => s.minflt,
            .majflt => s.majflt,
            .ctx_switches => s.vcsw + s.ivcsw,
            .inblock => s.inblock,
        };
    }
};

const Stats = struct { min: f64, median: f64, mean: f64, p95: f64, max: f64, stddev: f64 };

const metrics = [_]Metric{ .wall_us, .cpu_us, .cpu_pct, .maxrss_kb, .minflt, .majflt, .ctx_switches, .inblock };

/// Metrics gated against the baseline; the rest are informational.
const gated = [_]Metric{ .wall_us, .cpu_us, .maxrss_kb };

const Options = struct {
    bin: []const u8 = "./zig-out/bin/zero-noise",
    runs: usize = 30,
    warmup: usize = 3,
    json_path: ?[]const u8 = null,
    baseline_path: ?[]const u8 = null,
    max_regress_pct: f64 = 10.0,
    filter: ?[]const u8 = null,
};

fn nowUs() f64 {
    var ts: c.Timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) * 1e6 + @as(f64, @floatFromInt(ts.nsec)) / 1e3;
}

fn tvUs(tv: c.Timeval) f64 {
    return @as(f64, @floatFromInt(tv.sec)) * 1e6 + @as(f64, @floatFromInt(tv.usec));
}

fn runOnce(allocator: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Sample {
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len + 1, null);
    defer allocator.free(argv);
    const bin_z = try allocator.dupeSentinel(u8, bin, 0);
    defer allocator.free(bin_z);
    argv[0] = bin_z;
    var owned: usize = 0;
    defer for (argv[1 .. 1 + owned]) |p| allocator.free(std.mem.span(p.?));
    for (args, 0..) |a, i| {
        argv[i + 1] = (try allocator.dupeSentinel(u8, a, 0)).ptr;
        owned = i + 1;
    }

    const t0 = nowUs();
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const null_fd = c.open("/dev/null", c.O_WRONLY);
        _ = c.dup2(null_fd, 1);
        _ = c.dup2(null_fd, 2);
        _ = c.close(null_fd);
        _ = c.execv(bin_z, argv.ptr);
        c._exit(127);
    }

    var status: c_int = 0;
    var ru: c.Rusage = undefined;
    if (c.wait4(pid, &status, 0, &ru) < 0) return error.WaitFailed;
    const wall = nowUs() - t0;

    return .{
        .wall_us = wall,
        .user_us = tvUs(ru.utime),
        .sys_us = tvUs(ru.stime),
        .maxrss_kb = @floatFromInt(ru.maxrss),
        .minflt = @floatFromInt(ru.minflt),
        .majflt = @floatFromInt(ru.majflt),
        .vcsw = @floatFromInt(ru.nvcsw),
        .ivcsw = @floatFromInt(ru.nivcsw),
        .inblock = @floatFromInt(ru.inblock),
        .exit_code = @intCast((status >> 8) & 0xff),
    };
}

fn computeStats(values: []f64) Stats {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (values) |v| sum += v;
    const n: f64 = @floatFromInt(values.len);
    const mean = sum / n;
    var sq: f64 = 0;
    for (values) |v| sq += (v - mean) * (v - mean);
    const mid = values.len / 2;
    const median = if (values.len % 2 == 1) values[mid] else (values[mid - 1] + values[mid]) / 2.0;
    const p95_idx = @min(values.len - 1, @as(usize, @intFromFloat(@ceil(0.95 * n))) -| 1);
    return .{
        .min = values[0],
        .median = median,
        .mean = mean,
        .p95 = values[p95_idx],
        .max = values[values.len - 1],
        .stddev = @sqrt(sq / n),
    };
}

const Result = struct {
    name: []const u8,
    stats: [metrics.len]Stats,
    failures: usize,
};

fn measure(allocator: std.mem.Allocator, opts: Options, sc: Scenario) !Result {
    for (0..opts.warmup) |_| _ = try runOnce(allocator, opts.bin, sc.args);

    const samples = try allocator.alloc(Sample, opts.runs);
    defer allocator.free(samples);
    var failures: usize = 0;
    for (samples) |*s| {
        s.* = try runOnce(allocator, opts.bin, sc.args);
        if (s.exit_code == 127) return error.BinaryNotExecutable;
        if (s.exit_code > 1) failures += 1;
    }

    var result: Result = .{ .name = sc.name, .stats = undefined, .failures = failures };
    const buf = try allocator.alloc(f64, opts.runs);
    defer allocator.free(buf);
    inline for (metrics, 0..) |m, i| {
        for (samples, 0..) |s, k| buf[k] = m.of(s);
        result.stats[i] = computeStats(buf);
    }
    return result;
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const f = c.fopen(path, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    if (c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}

fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const f = c.fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn renderTable(allocator: std.mem.Allocator, out: *std.ArrayList(u8), results: []const Result, opts: Options) !void {
    try out.print(allocator, "bin={s} runs={d} warmup={d}\n\n", .{ opts.bin, opts.runs, opts.warmup });
    try out.print(allocator, "{s:<12} {s:<13} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11}\n", .{ "scenario", "metric", "min", "median", "p95", "max", "stddev" });
    for (results) |r| {
        inline for (metrics, 0..) |m, i| {
            const s = r.stats[i];
            try out.print(allocator, "{s:<12} {s:<13} {d:>11.1} {d:>11.1} {d:>11.1} {d:>11.1} {d:>11.1}\n", .{ r.name, m.label(), s.min, s.median, s.p95, s.max, s.stddev });
        }
        if (r.failures > 0) try out.print(allocator, "{s:<12} WARNING: {d} runs exited with code > 1\n", .{ r.name, r.failures });
        try out.append(allocator, '\n');
    }
}

fn renderJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), results: []const Result, opts: Options) !void {
    try out.print(allocator, "{{\"runs\":{d},\"warmup\":{d},\"scenarios\":{{", .{ opts.runs, opts.warmup });
    for (results, 0..) |r, ri| {
        if (ri > 0) try out.append(allocator, ',');
        try out.print(allocator, "\"{s}\":{{", .{r.name});
        inline for (metrics, 0..) |m, i| {
            const s = r.stats[i];
            if (i > 0) try out.append(allocator, ',');
            try out.print(allocator, "\"{s}\":{{\"min\":{d:.3},\"median\":{d:.3},\"mean\":{d:.3},\"p95\":{d:.3},\"max\":{d:.3},\"stddev\":{d:.3}}}", .{ m.label(), s.min, s.median, s.mean, s.p95, s.max, s.stddev });
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "}}\n");
}

/// Compares gated medians to the baseline; returns the regression count.
fn compareBaseline(allocator: std.mem.Allocator, out: *std.ArrayList(u8), results: []const Result, opts: Options, path: []const u8) !usize {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const data = try readFile(allocator, path_z);
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const base_scenarios = (parsed.value.object.get("scenarios") orelse return error.InvalidBaseline).object;
    var regressions: usize = 0;
    try out.print(allocator, "baseline: {s} (max regression {d:.1}%)\n", .{ path, opts.max_regress_pct });
    for (results) |r| {
        const base = base_scenarios.get(r.name) orelse {
            try out.print(allocator, "{s:<12} no baseline entry\n", .{r.name});
            continue;
        };
        inline for (metrics, 0..) |m, i| {
            if (comptime std.mem.indexOfScalar(Metric, &gated, m) != null) {
                const old = jsonNumber(base.object.get(m.label()).?.object.get("median").?);
                const new = r.stats[i].median;
                const delta = if (old > 0) (new - old) / old * 100.0 else 0;
                const bad = delta > opts.max_regress_pct;
                if (bad) regressions += 1;
                try out.print(allocator, "{s:<12} {s:<10} {d:>12.1} -> {d:>12.1} ({d:>7.1}%) {s}\n", .{ r.name, m.label(), old, new, delta, if (bad) "REGRESSION" else "ok" });
            }
        }
    }
    return regressions;
}

fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
}

fn parseOptions(args: []const []const u8) !Options {
    var opts: Options = .{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--runs=")) {
            opts.runs = try std.fmt.parseInt(usize, arg[7..], 10);
        } else if (std.mem.startsWith(u8, arg, "--warmup=")) {
            opts.warmup = try std.fmt.parseInt(usize, arg[9..], 10);
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            opts.json_path = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--baseline=")) {
            opts.baseline_path = arg[11..];
        } else if (std.mem.startsWith(u8, arg, "--max-regress=")) {
            opts.max_regress_pct = try std.fmt.parseFloat(f64, arg[14..]);
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "--bin=")) {
            opts.bin = arg[6..];
        } else {
            return error.UnknownArgument;
        }
    }
    if (opts.runs == 0) return error.InvalidRuns;
    return opts;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    const argv = try init.minimal.args.toSlice(allocator);
    const opts = parseOptions(argv[1..]) catch |err| {
        try stderr.writeStreamingAll(io, "usage: bench [--bin=PATH] [--runs=N] [--warmup=N] [--filter=NAME] [--json=OUT] [--baseline=FILE] [--max-regress=PCT]\n");
        return if (err == error.UnknownArgument or err == error.InvalidRuns) 2 else err;
    };

    var results: std.ArrayList(Result) = .empty;
    for (scenarios) |sc| {
        if (opts.filter) |f| if (std.mem.indexOf(u8, sc.name, f) == null) continue;
        try results.append(allocator, measure(allocator, opts, sc) catch |err| {
            try stderr.writeStreamingAll(io, "bench: cannot run binary (build it first with `zig build`)\n");
            return err;
        });
    }

    var out: std.ArrayList(u8) = .empty;
    try renderTable(allocator, &out, results.items, opts);

    var regressions: usize = 0;
    if (opts.baseline_path) |p| regressions = try compareBaseline(allocator, &out, results.items, opts, p);
    try stdout.writeStreamingAll(io, out.items);

    if (opts.json_path) |p| {
        var json: std.ArrayList(u8) = .empty;
        try renderJson(allocator, &json, results.items, opts);
        try writeFile(try allocator.dupeSentinel(u8, p, 0), json.items);
    }
    return if (regressions > 0) 1 else 0;
}
