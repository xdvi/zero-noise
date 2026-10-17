const std = @import("std");
const common = @import("common.zig");
const blast = @import("../analysis/blast.zig");
const complexity = @import("../analysis/complexity.zig");
const deps_mod = @import("deps.zig");
const grammars = @import("../treesitter/grammars.zig");

pub fn computeFileBlastRisk(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    content: []const u8,
    root_dir: []const u8,
    deps: *const deps_mod.Deps,
) blast.RiskLevel {
    const lang = grammars.Language.fromPath(filepath);
    if (lang == .unknown) return .low;

    const funcs = deps.calculateComplexity(allocator, content, lang) catch return .low;
    defer { for (funcs) |f| f.deinit(allocator); allocator.free(funcs); }

    if (funcs.len == 0) return .low;

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    var file_inputs: std.ArrayList(blast.FileInput) = .empty;
    defer {
        for (file_inputs.items) |fi| allocator.free(fi.content);
        file_inputs.deinit(allocator);
    }

    if (!prepareRiskFiles(allocator, deps, root_dir, &files_list, &file_inputs)) return .low;

    return maxRiskForFunctions(allocator, deps, funcs, file_inputs.items);
}

fn loadRiskFiles(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    files_list: *std.ArrayList([]const u8),
    file_inputs: *std.ArrayList(blast.FileInput),
) void {
    for (files_list.items) |fp| {
        const file_content = deps.fs.readFileAlloc(allocator, fp) catch continue;
        file_inputs.append(allocator, .{ .path = fp, .content = file_content }) catch {
            allocator.free(file_content);
            continue;
        };
    }
}

fn isCandidateFunction(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "anonymous")) return false;
    if (std.mem.eql(u8, name, "constructor")) return false;
    if (std.mem.startsWith(u8, name, "<")) return false;
    return true;
}

fn prepareRiskFiles(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    root_dir: []const u8,
    files_list: *std.ArrayList([]const u8),
    file_inputs: *std.ArrayList(blast.FileInput),
) bool {
    common.collectSourceFiles(allocator, root_dir, files_list) catch return false;
    if (files_list.items.len <= 1) return false;
    loadRiskFiles(allocator, deps, files_list, file_inputs);
    return true;
}

fn maxRiskForFunctions(
    allocator: std.mem.Allocator,
    deps: *const deps_mod.Deps,
    funcs: []complexity.FunctionRecord,
    file_inputs: []blast.FileInput,
) blast.RiskLevel {
    var max_risk: blast.RiskLevel = .low;
    for (funcs) |fn_rec| {
        if (!isCandidateFunction(fn_rec.name)) continue;
        var b_res = deps.analyzeBlastRadius(allocator, file_inputs, fn_rec.name) catch continue;
        defer b_res.deinit(allocator);
        if (b_res.risk == .high) return .high;
        if (b_res.risk == .medium) max_risk = .medium;
    }
    return max_risk;
}
