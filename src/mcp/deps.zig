const std = @import("std");

const runner = @import("../mutation/runner.zig");
const rewriter = @import("../mutation/rewriter.zig");
const propose = @import("../mutation/propose.zig");
const db_mod = @import("../storage/db.zig");
const noise = @import("../analysis/noise.zig");
const complexity = @import("../analysis/complexity.zig");
const blast = @import("../analysis/blast.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const FileSystem = struct {
    context: *anyopaque,
    readFileAllocFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,

    pub fn readFileAlloc(self: FileSystem, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        return self.readFileAllocFn(self.context, allocator, path);
    }
};

pub const DatabaseFactory = struct {
    context: *anyopaque,
    openFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!db_mod.Database,

    pub fn open(self: DatabaseFactory, allocator: std.mem.Allocator, root_path: []const u8) anyerror!db_mod.Database {
        return self.openFn(self.context, allocator, root_path);
    }
};

pub const Deps = struct {
    fs: FileSystem,
    db: DatabaseFactory,
    auditNoiseWithOptions: *const fn (std.mem.Allocator, []const u8, grammars.Language, noise.NoiseConfig) anyerror![]noise.NoiseFinding = defaultAuditNoiseWithOptions,
    calculateComplexity: *const fn (std.mem.Allocator, []const u8, grammars.Language) anyerror![]complexity.FunctionRecord = defaultCalculateComplexity,
    analyzeBlastRadius: *const fn (std.mem.Allocator, []const blast.FileInput, []const u8) anyerror!blast.BlastRadiusResult = defaultAnalyzeBlastRadius,
    simplify: *const fn (std.mem.Allocator, []const u8) anyerror![]u8 = defaultSimplify,
    collectProposals: *const fn (std.mem.Allocator, []const u8, grammars.Language, propose.KindFlags) anyerror!propose.CollectResult = defaultCollectProposals,
};

var default_context: u8 = 0;

fn defaultReadFileAlloc(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    _ = ctx;
    return runner.readFileAlloc(allocator, path);
}

fn defaultOpenProjectDb(ctx: *anyopaque, allocator: std.mem.Allocator, root_path: []const u8) anyerror!db_mod.Database {
    _ = ctx;
    return db_mod.openProjectDb(allocator, root_path);
}

fn defaultAuditNoiseWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    config: noise.NoiseConfig,
) anyerror![]noise.NoiseFinding {
    return noise.auditNoiseWithOptions(allocator, source, lang, config);
}

fn defaultCalculateComplexity(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
) anyerror![]complexity.FunctionRecord {
    return complexity.calculateComplexity(allocator, source, lang);
}

fn defaultAnalyzeBlastRadius(
    allocator: std.mem.Allocator,
    files: []const blast.FileInput,
    symbol: []const u8,
) anyerror!blast.BlastRadiusResult {
    return blast.analyzeBlastRadius(allocator, files, symbol);
}

fn defaultSimplify(allocator: std.mem.Allocator, source: []const u8) anyerror![]u8 {
    return rewriter.simplify(allocator, source);
}

fn defaultCollectProposals(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    flags: propose.KindFlags,
) anyerror!propose.CollectResult {
    return propose.collectProposals(allocator, source, lang, flags);
}

pub fn defaultDeps() Deps {
    return .{
        .fs = .{ .context = @ptrCast(&default_context), .readFileAllocFn = defaultReadFileAlloc },
        .db = .{ .context = @ptrCast(&default_context), .openFn = defaultOpenProjectDb },
        .auditNoiseWithOptions = defaultAuditNoiseWithOptions,
        .calculateComplexity = defaultCalculateComplexity,
        .analyzeBlastRadius = defaultAnalyzeBlastRadius,
        .simplify = defaultSimplify,
        .collectProposals = defaultCollectProposals,
    };
}
