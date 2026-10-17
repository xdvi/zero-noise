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
    common.collectSourceFiles(allocator, root_dir, &files_list) catch return .low;
    if (files_list.items.len <= 1) return .low;

    var file_inputs: std.ArrayList(blast.FileInput) = .empty;
    defer {
        for (file_inputs.items) |fi| allocator.free(fi.content);
        file_inputs.deinit(allocator);
    }

    for (files_list.items) |fp| {
        const file_content = deps.fs.readFileAlloc(allocator, fp) catch continue;
        file_inputs.append(allocator, .{ .path = fp, .content = file_content }) catch {
            allocator.free(file_content);
            continue;
        };
    }

    var max_risk: blast.RiskLevel = .low;

    for (funcs) |fn_rec| {
        if (fn_rec.name.len == 0 or std.mem.eql(u8, fn_rec.name, "anonymous") or std.mem.eql(u8, fn_rec.name, "constructor") or std.mem.startsWith(u8, fn_rec.name, "<")) {
            continue;
        }

        var b_res = deps.analyzeBlastRadius(allocator, file_inputs.items, fn_rec.name) catch continue;
        defer b_res.deinit(allocator);

        if (b_res.risk == .high) {
            return .high;
        } else if (b_res.risk == .medium) {
            max_risk = .medium;
        }
    }

    return max_risk;
}
