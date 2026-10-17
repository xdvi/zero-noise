const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .debug);
    const is_linux = target.result.os.tag == .linux;
    const lto: ?std.zig.LtoMode = b.option(std.zig.LtoMode, "lto", "Link-Time Optimization mode") orelse (if (optimize != .debug and is_linux) .thin else null);

    var c_flags_list: std.ArrayList([]const u8) = .empty;
    c_flags_list.appendSlice(b.allocator, &.{
        "-std=c11",
        "-D_DEFAULT_SOURCE",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_ENABLE_WAL=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    }) catch unreachable;
    if (lto != null and lto.? != .none) {
        c_flags_list.append(b.allocator, "-flto") catch unreachable;
    }
    if (target.result.os.tag.isDarwin()) {
        c_flags_list.append(b.allocator, "-D_DARWIN_C_SOURCE") catch unreachable;
    } else {
        c_flags_list.append(b.allocator, "-D_POSIX_C_SOURCE=200809L") catch unreachable;
    }
    const c_flags = c_flags_list.items;

    // Module for zero-noise core
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    mod.addIncludePath(b.path("c"));
    mod.addIncludePath(b.path("c/vendor/tree-sitter/lib/include"));
    mod.addIncludePath(b.path("c/vendor/tree-sitter/lib/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/go/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/rust/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/python/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/typescript/typescript/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/typescript/tsx/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/c_sharp/src"));
    mod.addIncludePath(b.path("c/vendor/grammars/zig/src"));

    // Core sources (tree-sitter only; storage is file-based now).
    const core_sources: []const []const u8 = &.{
        "c/vendor/tree-sitter/lib/src/lib.c",
    };

    for (core_sources) |src| {
        mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = c_flags,
        });
    }

    // Grammar shared libraries are built separately below.

    mod.link_libc = true;

    // Executable
    const exe = b.addExecutable(.{
        .name = "zero-noise",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "zero-noise", .module = mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    if (lto) |m| {
        exe.lto = m;
    }

    // Build grammar shared libraries for dynamic loading.
    const grammar_specs = [_]struct { name: []const u8, sources: []const []const u8, includes: []const []const u8 }{
        .{ .name = "go", .sources = &.{ "c/vendor/grammars/go/src/parser.c" }, .includes = &.{ "c/vendor/grammars/go/src" } },
        .{ .name = "rust", .sources = &.{ "c/vendor/grammars/rust/src/parser.c", "c/vendor/grammars/rust/src/scanner.c" }, .includes = &.{ "c/vendor/grammars/rust/src" } },
        .{ .name = "python", .sources = &.{ "c/vendor/grammars/python/src/parser.c", "c/vendor/grammars/python/src/scanner.c" }, .includes = &.{ "c/vendor/grammars/python/src" } },
        .{ .name = "typescript", .sources = &.{ "c/vendor/grammars/typescript/typescript/src/parser.c", "c/vendor/grammars/typescript/typescript/src/scanner.c" }, .includes = &.{ "c/vendor/grammars/typescript/typescript/src" } },
        .{ .name = "tsx", .sources = &.{ "c/vendor/grammars/typescript/tsx/src/parser.c", "c/vendor/grammars/typescript/tsx/src/scanner.c" }, .includes = &.{ "c/vendor/grammars/typescript/tsx/src" } },
        .{ .name = "c_sharp", .sources = &.{ "c/vendor/grammars/c_sharp/src/parser.c", "c/vendor/grammars/c_sharp/src/scanner.c" }, .includes = &.{ "c/vendor/grammars/c_sharp/src" } },
        .{ .name = "zig", .sources = &.{ "c/vendor/grammars/zig/src/parser.c" }, .includes = &.{ "c/vendor/grammars/zig/src" } },
    };

    for (grammar_specs) |spec| {
        const lib = b.addLibrary(.{
            .name = b.fmt("tree-sitter-{s}", .{spec.name}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .strip = strip,
            }),
            .linkage = .dynamic,
        });
        lib.root_module.link_libc = true;
        for (spec.includes) |inc| {
            lib.root_module.addIncludePath(b.path(inc));
        }
        lib.root_module.addIncludePath(b.path("c"));
        lib.root_module.addIncludePath(b.path("c/vendor/tree-sitter/lib/include"));
        lib.root_module.addIncludePath(b.path("c/vendor/tree-sitter/lib/src"));
        for (spec.sources) |src| {
            lib.root_module.addCSourceFile(.{ .file = b.path(src), .flags = c_flags });
        }
        b.installArtifact(lib);
    }

    b.installArtifact(exe);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run library and integration tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_mod_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "zero-noise-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    bench_exe.root_module.link_libc = true;
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    run_bench.step.dependOn(b.getInstallStep());
    const bench_args = b.option([]const u8, "bench-args", "Space-separated arguments forwarded to the bench step");
    if (bench_args) |raw| {
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        while (it.next()) |arg| run_bench.addArg(arg);
    }
    const bench_step = b.step("bench", "Run benchmarks (CPU, RSS, faults) against zig-out/bin/zero-noise");
    bench_step.dependOn(&run_bench.step);
}
