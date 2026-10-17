const std = @import("std");
const protocol = @import("protocol.zig");
const compact = @import("compact.zig");
const noise = @import("../analysis/noise.zig");
const complexity = @import("../analysis/complexity.zig");
const blast = @import("../analysis/blast.zig");
const runner = @import("../mutation/runner.zig");
const rewriter = @import("../mutation/rewriter.zig");
const grammars = @import("../treesitter/grammars.zig");
const db_mod = @import("../storage/db.zig");
const ledger_mod = @import("../storage/ledger.zig");

pub const ToolResult = struct {
    text: []const u8,
    is_error: bool,
    count: usize = 0,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: ?std.json.Value,
) !ToolResult {
    const ToolHandler = *const fn (std.mem.Allocator, ?std.json.Value) anyerror!ToolResult;
    const ToolEntry = struct { name: []const u8, handler: ToolHandler };
    const tool_table = [_]ToolEntry{
        .{ .name = "audit_noise", .handler = executeAuditNoise },
        .{ .name = "refactor_helper", .handler = executeRefactorHelper },
        .{ .name = "blast_radius", .handler = executeBlastRadius },
        .{ .name = "inspect_evidence", .handler = executeInspectEvidence },
        .{ .name = "evidence_contract", .handler = executeInspectEvidence },
        .{ .name = "safe_refactor", .handler = executeSafeRefactor },
        .{ .name = "complexity", .handler = executeComplexity },
        .{ .name = "evaluate_rules", .handler = executeEvaluateRules },
    };
    for (tool_table) |entry| {
        if (std.mem.eql(u8, tool_name, entry.name)) {
            return entry.handler(allocator, args);
        }
    }
    const msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
    return ToolResult{ .text = msg, .is_error = true };
}

fn getStringArg(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    if (args) |v| {
        if (v == .object) {
            if (v.object.get(key)) |val| {
                if (val == .string) return val.string;
            }
        }
    }
    return null;
}

fn getIntArg(args: ?std.json.Value, key: []const u8, default_val: i64) i64 {
    if (args) |v| {
        if (v == .object) {
            if (v.object.get(key)) |val| {
                if (val == .integer) {
                    if (val.integer >= 0 and val.integer <= std.math.maxInt(u32)) {
                        return val.integer;
                    }
                    return default_val;
                }
            }
        }
    }
    return default_val;
}

fn getU32Arg(args: ?std.json.Value, key: []const u8, default_val: u32) u32 {
    const raw = getIntArg(args, key, default_val);
    if (raw >= 0 and raw <= std.math.maxInt(u32)) {
        return @intCast(raw);
    }
    return default_val;
}

fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    try list.print(allocator, "{f}", .{std.json.fmt(str, .{})});
}

fn openAnyFile(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options);
    } else {
        return std.Io.Dir.cwd().openFile(io, path, options);
    }
}

fn openAnyDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const clean_path = if (trimmed.len == 0) (if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) "/" else ".") else trimmed;
    if (std.fs.path.isAbsolute(clean_path)) {
        return std.Io.Dir.openDirAbsolute(io, clean_path, options);
    } else {
        return std.Io.Dir.cwd().openDir(io, clean_path, options);
    }
}

fn collectSourceFiles(allocator: std.mem.Allocator, root_path: []const u8, files_list: *std.ArrayList([]const u8)) !void {
    const io = std.Options.debug_io;

    if (openAnyDir(io, root_path, .{ .iterate = true })) |*opened_dir| {
        var dir = opened_dir.*;
        defer dir.close(io);

        var walker = dir.walkSelectively(allocator) catch return;
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            const name = entry.basename;
            if (std.mem.startsWith(u8, name, ".") or
                std.mem.eql(u8, name, "node_modules") or
                std.mem.eql(u8, name, "target") or
                std.mem.eql(u8, name, "zig-out") or
                std.mem.eql(u8, name, "zig-cache") or
                std.mem.eql(u8, name, "bin") or
                std.mem.eql(u8, name, "obj"))
            {
                continue;
            }

            if (entry.kind == .directory) {
                try walker.enter(io, entry);
            } else {
                const lang = grammars.Language.fromPath(entry.basename);
                if (lang != .unknown) {
                    const trimmed_root = std.mem.trimEnd(u8, root_path, "/\\");
                    const full = if (std.mem.eql(u8, trimmed_root, "."))
                        try allocator.dupe(u8, entry.path)
                    else
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_root, entry.path });
                    try files_list.append(allocator, full);
                }
            }
        }
        return;
    } else |_| {}

    if (openAnyFile(io, root_path, .{})) |f| {
        f.close(io);
        const lang = grammars.Language.fromPath(root_path);
        if (lang != .unknown) {
            try files_list.append(allocator, try allocator.dupe(u8, root_path));
        }
        return;
    } else |_| {}
}

fn computeFileBlastRisk(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    content: []const u8,
    root_dir: []const u8,
) blast.RiskLevel {
    const lang = grammars.Language.fromPath(filepath);
    if (lang == .unknown) return .low;

    const funcs = complexity.calculateComplexity(allocator, content, lang) catch return .low;
    defer allocator.free(funcs);

    if (funcs.len == 0) return .low;

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    collectSourceFiles(allocator, root_dir, &files_list) catch return .low;
    if (files_list.items.len <= 1) return .low;

    var file_inputs: std.ArrayList(blast.FileInput) = .empty;
    defer {
        for (file_inputs.items) |fi| allocator.free(fi.content);
        file_inputs.deinit(allocator);
    }

    for (files_list.items) |fp| {
        const file_content = runner.readFileAlloc(allocator, fp) catch continue;
        file_inputs.append(allocator, .{ .path = fp, .content = file_content }) catch {
            allocator.free(file_content);
            continue;
        };
    }

    const parsed_files = blast.parseFileInputs(allocator, file_inputs.items) catch return .low;
    defer blast.deinitParsedFiles(allocator, parsed_files);

    var max_risk: blast.RiskLevel = .low;

    for (funcs) |fn_rec| {
        if (fn_rec.name.len == 0 or std.mem.eql(u8, fn_rec.name, "anonymous") or std.mem.eql(u8, fn_rec.name, "constructor") or std.mem.startsWith(u8, fn_rec.name, "<")) {
            continue;
        }

        var b_res = blast.analyzeBlastRadiusParsed(allocator, parsed_files, fn_rec.name) catch continue;
        defer b_res.deinit(allocator);

        if (b_res.risk == .high) {
            return .high;
        } else if (b_res.risk == .medium) {
            max_risk = .medium;
        }
    }

    return max_risk;
}



const FindingItem = struct {
    file: []const u8,
    rule: noise.NoiseRule,
    line: u32,
    column: u32,
    message: []const u8,

    pub fn deinit(self: FindingItem, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.message);
    }
};

fn executeAuditNoise(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const format = getStringArg(args, "format") orelse "text";
    if (std.mem.eql(u8, format, "evidence")) {
        return executeInspectEvidence(allocator, args);
    }

    const path = getStringArg(args, "path") orelse ".";

    var noise_cfg = noise.NoiseConfig{};
    var ignore_patterns: std.ArrayList([]const u8) = .empty;
    defer {
        for (ignore_patterns.items) |pat| allocator.free(pat);
        ignore_patterns.deinit(allocator);
    }

    if (getStringArg(args, "config")) |cfg_path| {
        if (runner.readFileAlloc(allocator, cfg_path)) |cfg_content| {
            defer allocator.free(cfg_content);
            if (std.json.parseFromSlice(std.json.Value, allocator, cfg_content, .{})) |parsed_cfg| {
                defer parsed_cfg.deinit();
                if (parsed_cfg.value == .object) {
                    if (parsed_cfg.value.object.get("max_nesting")) |v| {
                        if (v == .integer and v.integer >= 0) {
                            noise_cfg.max_nesting = @intCast(v.integer);
                        }
                    }
                    if (parsed_cfg.value.object.get("max_closure_len")) |v| {
                        if (v == .integer and v.integer >= 0) {
                            noise_cfg.max_closure_len = @intCast(v.integer);
                        }
                    }
                    if (parsed_cfg.value.object.get("ignore_patterns")) |v| {
                        if (v == .array) {
                            for (v.array.items) |item| {
                                if (item == .string) {
                                    try ignore_patterns.append(allocator, try allocator.dupe(u8, item.string));
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        } else |_| {}
    }

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try collectSourceFiles(allocator, path, &files_list);

    var all_findings: std.ArrayList(FindingItem) = .empty;
    defer {
        for (all_findings.items) |item| item.deinit(allocator);
        all_findings.deinit(allocator);
    }

    for (files_list.items) |file_path| {
        var ignored = false;
        for (ignore_patterns.items) |pat| {
            if (std.mem.indexOf(u8, file_path, pat) != null) {
                ignored = true;
                break;
            }
        }
        if (ignored) continue;

        const lang = grammars.Language.fromPath(file_path);
        if (lang == .unknown) continue;

        const content = runner.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        const findings = noise.auditNoiseWithOptions(allocator, content, lang, noise_cfg) catch continue;
        defer noise.deinitFindings(allocator, findings);

        for (findings) |f| {
            try all_findings.append(allocator, .{
                .file = try allocator.dupe(u8, file_path),
                .rule = f.rule,
                .line = f.line,
                .column = f.column,
                .message = try allocator.dupe(u8, f.message),
            });
        }
    }

    if (compact.isCompact(format)) {
        if (all_findings.items.len == 0) {
            const text = try compact.formatNoise(allocator, path, 1, 1, "audit_noise", "0 structural noise violations detected.");
            return ToolResult{ .text = text, .is_error = false, .count = 0 };
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (all_findings.items) |item| {
            const line = try compact.formatNoise(allocator, item.file, item.line, item.column, item.rule.asString(), item.message);
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"path\":");
        try appendJsonEscaped(&buf, allocator, path);
        try buf.appendSlice(allocator, ",\"violations\":[");
        for (all_findings.items, 0..) |item, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"file\":");
            try appendJsonEscaped(&buf, allocator, item.file);
            try buf.appendSlice(allocator, ",\"rule\":");
            try appendJsonEscaped(&buf, allocator, item.rule.asString());
            try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{
                item.line,
                item.column,
            });
            try appendJsonEscaped(&buf, allocator, item.message);
            try buf.append(allocator, '}');
        }
        try buf.print(allocator, "],\"total_noise\":{d}}}", .{all_findings.items.len});
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
    }

    if (std.mem.eql(u8, format, "sarif")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"zero-noise\",\"version\":\"0.1.0\"}},\"results\":[");
        for (all_findings.items, 0..) |item, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"ruleId\":");
            try appendJsonEscaped(&buf, allocator, item.rule.asString());
            try buf.appendSlice(allocator, ",\"message\":{\"text\":");
            try appendJsonEscaped(&buf, allocator, item.message);
            try buf.appendSlice(allocator, "},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
            try appendJsonEscaped(&buf, allocator, item.file);
            try buf.appendSlice(allocator, "},\"region\":{\"startLine\":");
            try buf.print(allocator, "{d}", .{item.line});
            try buf.appendSlice(allocator, ",\"startColumn\":");
            try buf.print(allocator, "{d}", .{item.column});
            try buf.appendSlice(allocator, "}}}]}");
        }
        try buf.appendSlice(allocator, "]}]}");
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
    }

    if (all_findings.items.len == 0) {
        const text = try std.fmt.allocPrint(allocator, "Zero-Noise Audit: {s} - 0 violations found.", .{path});
        return ToolResult{ .text = text, .is_error = false, .count = 0 };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Zero-Noise Audit: {s} - {d} structural noise violation(s) found:\n", .{ path, all_findings.items.len });
    for (all_findings.items) |item| {
        try buf.print(allocator, "  {s}:{d}:{d} [{s}] {s}\n", .{
            item.file,
            item.line,
            item.column,
            item.rule.asString(),
            item.message,
        });
    }
    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
}

fn executeRefactorHelper(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const filepath = getStringArg(args, "filepath") orelse "";
    const content = runner.readFileAlloc(allocator, filepath) catch {
        const text = try std.fmt.allocPrint(allocator, "Refactor Helper ({s}): No repeated literals or boolean simplifications required.", .{filepath});
        return ToolResult{ .text = text, .is_error = false };
    };
    defer allocator.free(content);

    const lang = grammars.Language.fromPath(filepath);
    var findings: []noise.NoiseFinding = &.{};
    if (lang != .unknown) {
        findings = noise.auditNoise(allocator, content, lang) catch &.{};
    }
    defer if (findings.len > 0) noise.deinitFindings(allocator, findings);

    var repeated_count: usize = 0;
    var ternary_count: usize = 0;
    for (findings) |f| {
        if (f.rule == .repeated_literal) repeated_count += 1;
        if (f.rule == .redundant_ternary) ternary_count += 1;
    }

    const simplified = rewriter.simplify(allocator, content) catch null;
    defer if (simplified) |s| allocator.free(s);

    const has_algebraic = if (simplified) |s| !std.mem.eql(u8, s, content) else false;

    if (repeated_count == 0 and ternary_count == 0 and !has_algebraic) {
        const text = try std.fmt.allocPrint(allocator, "Refactor Helper ({s}): No repeated literals or boolean simplifications required.", .{filepath});
        return ToolResult{ .text = text, .is_error = false };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Refactor Helper ({s}):\n", .{filepath});
    for (findings) |f| {
        if (f.rule == .repeated_literal or f.rule == .redundant_ternary) {
            try buf.print(allocator, "  Line {d}: [{s}] {s}\n", .{ f.line, f.rule.asString(), f.message });
        }
    }
    if (has_algebraic) {
        try buf.appendSlice(allocator, "  Boolean simplification candidate detected: algebraic reduction available via safe_refactor.\n");
    }

    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn executeBlastRadius(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const symbol = getStringArg(args, "symbol") orelse "";
    const root_dir = getStringArg(args, "root") orelse ".";
    const format = getStringArg(args, "format") orelse "text";

    if (symbol.len == 0) {
        return ToolResult{ .text = try allocator.dupe(u8, "Error: symbol argument is required"), .is_error = true };
    }

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try collectSourceFiles(allocator, root_dir, &files_list);

    var file_inputs: std.ArrayList(blast.FileInput) = .empty;
    defer {
        for (file_inputs.items) |fi| allocator.free(fi.content);
        file_inputs.deinit(allocator);
    }

    for (files_list.items) |fp| {
        const content = runner.readFileAlloc(allocator, fp) catch continue;
        try file_inputs.append(allocator, .{ .path = fp, .content = content });
    }

    var result = try blast.analyzeBlastRadius(allocator, file_inputs.items, symbol);
    defer result.deinit(allocator);

    if (db_mod.openProjectDb(allocator, root_dir)) |db_inst| {
        var db = db_inst;
        defer db.close();
        var ledger = ledger_mod.RefactorLedger.init(db, allocator);
        for (result.references) |ref| {
            ledger.recordSymbol(symbol, ref.file, ref.line, ref.column, ref.is_definition) catch {};
        }
    } else |_| {}

    var defs_count: u32 = 0;
    var refs_count: u32 = 0;
    for (result.references) |ref| {
        if (ref.is_definition) defs_count += 1 else refs_count += 1;
    }

    if (compact.isCompact(format)) {
        const text = try compact.formatBlast(allocator, symbol, defs_count, refs_count, result.files_count, result.risk.asString());
        return ToolResult{ .text = text, .is_error = false };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"symbol\":");
        try appendJsonEscaped(&buf, allocator, symbol);
        try buf.print(allocator, ",\"definitions\":{d},\"references\":{d},\"files\":{d},\"risk\":", .{
            defs_count, refs_count, result.files_count,
        });
        try appendJsonEscaped(&buf, allocator, result.risk.asString());
        try buf.appendSlice(allocator, ",\"usages\":[");
        for (result.references, 0..) |ref, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"file\":");
            try appendJsonEscaped(&buf, allocator, ref.file);
            try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"is_definition\":{s}}}", .{
                ref.line, ref.column, if (ref.is_definition) "true" else "false",
            });
        }
        try buf.appendSlice(allocator, "]}");
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Blast Radius for '{s}': Risk level {s} ({d} definition, {d} references across {d} file(s)).\n", .{
        symbol,
        switch (result.risk) {
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
        },
        defs_count,
        refs_count,
        result.files_count,
    });
    for (result.references) |ref| {
        try buf.print(allocator, "  {s}:{d}:{d} [{s}]\n", .{
            ref.file, ref.line, ref.column, if (ref.is_definition) "DEF" else "REF",
        });
    }
    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn executeInspectEvidence(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const path = getStringArg(args, "path") orelse (getStringArg(args, "filepath") orelse "");
    if (path.len == 0) {
        return ToolResult{ .text = try allocator.dupe(u8, "Error: path argument is required"), .is_error = true };
    }

    const content = runner.readFileAlloc(allocator, path) catch {
        const text = try std.fmt.allocPrint(allocator, "Error: target file not found: {s}", .{path});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer allocator.free(content);

    const root = getStringArg(args, "root") orelse ".";
    const page_raw = getU32Arg(args, "page", 1);
    const page: u32 = if (page_raw == 0) 1 else page_raw;
    const page_size_raw = getU32Arg(args, "page_size", 10);
    const page_size: u32 = if (page_size_raw == 0) 10 else page_size_raw;

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const actual_hash = std.fmt.bytesToHex(digest, .lower);

    const lang = grammars.Language.fromPath(path);
    var findings: []noise.NoiseFinding = &.{};
    if (lang != .unknown) {
        findings = noise.auditNoise(allocator, content, lang) catch &.{};
    }
    defer if (findings.len > 0) noise.deinitFindings(allocator, findings);

    var max_complexity: u32 = 0;
    if (lang != .unknown) {
        const records = complexity.calculateComplexity(allocator, content, lang) catch &.{};
        defer allocator.free(records);
        for (records) |r| {
            if (r.complexity > max_complexity) max_complexity = r.complexity;
        }
    }

    const blast_risk = computeFileBlastRisk(allocator, path, content, root);
    const total_findings = findings.len;
    const priority_score: u32 = switch (blast_risk) {
        .low => (max_complexity * 2 + @as(u32, @intCast(total_findings)) * 3),
        .medium => (max_complexity * 2 + @as(u32, @intCast(total_findings)) * 3) / 2,
        .high => (max_complexity * 2 + @as(u32, @intCast(total_findings)) * 3) / 4,
    };

    const start_idx: usize = @min(@as(usize, page - 1) * @as(usize, page_size), total_findings);
    const end_idx: usize = @min(start_idx + @as(usize, page_size), total_findings);
    const page_findings = findings[start_idx..end_idx];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"file\":");
    try appendJsonEscaped(&buf, allocator, path);
    try buf.print(allocator, ",\"state_lock_sha256\":\"{s}\",\"metrics\":{{\"noise_count\":{d},\"cognitive_complexity\":{d},\"blast_radius_risk\":", .{
        actual_hash, total_findings, max_complexity,
    });
    try appendJsonEscaped(&buf, allocator, blast_risk.asString());
    try buf.print(allocator, ",\"priority_score\":{d}", .{priority_score});
    try buf.appendSlice(allocator, "},\"findings\":[");
    for (page_findings, 0..) |f, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"rule\":");
        try appendJsonEscaped(&buf, allocator, f.rule.asString());
        try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{
            f.line, f.column,
        });
        try appendJsonEscaped(&buf, allocator, f.message);
        try buf.append(allocator, '}');
    }
    try buf.print(allocator, "],\"page\":{d},\"page_size\":{d},\"total\":{d}}}", .{ page, page_size, total_findings });

    if (db_mod.openProjectDb(allocator, root)) |db_inst| {
        var db = db_inst;
        defer db.close();
        db.recordFileCacheSlice(allocator, path, 0, @intCast(content.len), &actual_hash, @intCast(total_findings), @intCast(max_complexity)) catch {};
    } else |_| {}

    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn executeSafeRefactor(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const filepath = getStringArg(args, "filepath") orelse "";
    const format = getStringArg(args, "format") orelse "text";
    const expected_hash = getStringArg(args, "expected_hash");
    const test_cmd = getStringArg(args, "test_cmd");
    const root = getStringArg(args, "root") orelse ".";
    const max_blast_risk_str = getStringArg(args, "max_blast_risk");
    const patch_file = getStringArg(args, "patch_file");
    const candidate_content = getStringArg(args, "candidate_content");
    var target_patch: ?[]const u8 = null;
    defer if (target_patch) |tp| allocator.free(tp);

    if (patch_file) |pf| {
        target_patch = runner.readFileAlloc(allocator, pf) catch null;
    }

    var maybe_db = db_mod.openProjectDb(allocator, root) catch null;
    defer if (maybe_db) |*db| db.close();

    var maybe_ledger: ?ledger_mod.RefactorLedger = if (maybe_db) |db|
        ledger_mod.RefactorLedger.init(db, allocator)
    else
        null;

    var task_id: ?[]const u8 = null;
    defer if (task_id) |tid| allocator.free(tid);

    if (maybe_ledger) |*ledger| {
        task_id = ledger.createTask(filepath, expected_hash orelse "unlocked", 0, 0) catch null;
    }

    const force = if (args) |v| blk: {
        if (v == .object) {
            if (v.object.get("force")) |val| {
                if (val == .bool) break :blk val.bool;
            }
        }
        break :blk false;
    } else false;
    const fix = if (args) |v| blk: {
        if (v == .object) {
            if (v.object.get("fix")) |val| {
                if (val == .bool) break :blk val.bool;
            }
        }
        break :blk true;
    } else true;

    // Enforcement of max_blast_risk
    if (max_blast_risk_str) |mbr| {
        if (!force) {
            const allowed_opt: ?blast.RiskLevel = if (std.mem.eql(u8, mbr, "low"))
                .low
            else if (std.mem.eql(u8, mbr, "medium"))
                .medium
            else if (std.mem.eql(u8, mbr, "high"))
                .high
            else
                null;

            if (allowed_opt) |allowed| {
                const target_content = runner.readFileAlloc(allocator, filepath) catch null;
                defer if (target_content) |tc| allocator.free(tc);

                if (target_content) |tc| {
                    const actual_risk = computeFileBlastRisk(allocator, filepath, tc, root);
                    const risk_val: u8 = switch (actual_risk) {
                        .low => 1,
                        .medium => 2,
                        .high => 3,
                    };
                    const allowed_val: u8 = switch (allowed) {
                        .low => 1,
                        .medium => 2,
                        .high => 3,
                    };

                    if (risk_val > allowed_val) {
                        if (maybe_ledger) |*ledger| {
                            if (task_id) |tid| {
                                ledger.updateTaskStatus(tid, "aborted") catch {};
                            }
                        }
                        const err_msg = try std.fmt.allocPrint(
                            allocator,
                            "Blast radius risk '{s}' exceeds maximum allowed risk '{s}' (use force=true to override)",
                            .{ actual_risk.asString(), mbr },
                        );
                        defer allocator.free(err_msg);

                        if (compact.isCompact(format)) {
                            const text = try compact.formatRefactor(allocator, filepath, "aborted", expected_hash orelse "unlocked", err_msg);
                            return ToolResult{ .text = text, .is_error = true };
                        }

                        if (std.mem.eql(u8, format, "json")) {
                            var buf: std.ArrayList(u8) = .empty;
                            defer buf.deinit(allocator);
                            try buf.appendSlice(allocator, "{\"filepath\":");
                            try appendJsonEscaped(&buf, allocator, filepath);
                            try buf.appendSlice(allocator, ",\"status\":\"aborted\",\"diff\":\"\",\"error\":");
                            try appendJsonEscaped(&buf, allocator, err_msg);
                            try buf.append(allocator, '}');
                            return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = true };
                        }

                        const text = try std.fmt.allocPrint(allocator, "Safe Refactor ({s}): status aborted\nError: {s}\n", .{ filepath, err_msg });
                        return ToolResult{ .text = text, .is_error = true };
                    }
                }
            }
        }
    }

    var result = runner.executeSafeRefactor(allocator, .{
        .filepath = filepath,
        .hash = .{ .expected_hash = expected_hash },
        .test_run = .{ .test_cmd = test_cmd },
        .fix = fix,
        .patch = .{
            .candidate_content = candidate_content,
            .patch_file = patch_file,
            .patch_content = target_patch,
        },
    }) catch |err| {
        if (maybe_ledger) |*ledger| {
            if (task_id) |tid| {
                ledger.updateTaskStatus(tid, "aborted") catch {};
            }
        }
        const text = try std.fmt.allocPrint(allocator, "Safe refactor error: {s}", .{@errorName(err)});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer result.deinit(allocator);

    const status_str = result.status.asString();

    if (maybe_ledger) |*ledger| {
        if (task_id) |tid| {
            ledger.updateTaskStatus(tid, status_str) catch {};
        }
    }

    if (compact.isCompact(format)) {
        const text = try compact.formatRefactor(allocator, filepath, status_str, expected_hash orelse "unlocked", if (result.error_msg) |em| em else "safe refactor completed");
        return ToolResult{ .text = text, .is_error = (result.status == .aborted or result.status == .rolled_back) };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"filepath\":");
        try appendJsonEscaped(&buf, allocator, filepath);
        try buf.print(allocator, ",\"status\":\"{s}\",\"diff\":", .{status_str});
        try appendJsonEscaped(&buf, allocator, result.diff);
        if (result.error_msg) |em| {
            try buf.appendSlice(allocator, ",\"error\":");
            try appendJsonEscaped(&buf, allocator, em);
        }
        try buf.append(allocator, '}');
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = (result.status == .aborted or result.status == .rolled_back) };
    }

    if (result.error_msg) |em| {
        const text = try std.fmt.allocPrint(allocator, "Safe Refactor ({s}): status {s}\nError: {s}\n", .{ filepath, status_str, em });
        return ToolResult{ .text = text, .is_error = true };
    }

    const text = try std.fmt.allocPrint(allocator, "Safe Refactor: {s} verified and applied successfully (hash: {s}).\n{s}", .{ filepath, expected_hash orelse "unlocked", result.diff });
    return ToolResult{ .text = text, .is_error = false };
}

const FuncItem = struct {
    file: []const u8,
    name: []const u8,
    line: u32,
    end_line: u32,
    complexity: u32,

    pub fn deinit(self: FuncItem, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.name);
    }
};

fn executeComplexity(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const path = getStringArg(args, "path") orelse ".";
    const threshold = getU32Arg(args, "threshold", 15);
    const format = getStringArg(args, "format") orelse "text";

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try collectSourceFiles(allocator, path, &files_list);

    var all_funcs: std.ArrayList(FuncItem) = .empty;
    defer {
        for (all_funcs.items) |item| item.deinit(allocator);
        all_funcs.deinit(allocator);
    }

    for (files_list.items) |file_path| {
        const lang = grammars.Language.fromPath(file_path);
        if (lang == .unknown) continue;

        const content = runner.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        const records = complexity.calculateComplexity(allocator, content, lang) catch continue;
        defer allocator.free(records);

        for (records) |rec| {
            if (rec.complexity >= threshold or std.mem.eql(u8, format, "json") or std.mem.eql(u8, format, "sarif")) {
                try all_funcs.append(allocator, .{
                    .file = try allocator.dupe(u8, file_path),
                    .name = try allocator.dupe(u8, rec.name),
                    .line = rec.line,
                    .end_line = rec.end_line,
                    .complexity = rec.complexity,
                });
            }
        }
    }

    var exceeded_count: usize = 0;
    for (all_funcs.items) |item| {
        if (item.complexity >= threshold) exceeded_count += 1;
    }

    if (compact.isCompact(format)) {
        if (exceeded_count == 0) {
            const text = try compact.formatComplexity(allocator, path, 1, "all_functions", 0, threshold);
            return ToolResult{ .text = text, .is_error = false, .count = 0 };
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (all_funcs.items) |item| {
            if (item.complexity >= threshold) {
                const line = try compact.formatComplexity(allocator, item.file, item.line, item.name, item.complexity, threshold);
                defer allocator.free(line);
                try buf.appendSlice(allocator, line);
                try buf.append(allocator, '\n');
            }
        }
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
    }

    if (std.mem.eql(u8, format, "sarif")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"zero-noise\",\"version\":\"0.1.0\"}},\"results\":[");
        var first = true;
        for (all_funcs.items) |item| {
            if (item.complexity >= threshold) {
                if (!first) try buf.append(allocator, ',');
                first = false;
                const msg = try std.fmt.allocPrint(allocator, "Function '{s}' cognitive complexity {d} exceeds threshold {d}", .{ item.name, item.complexity, threshold });
                defer allocator.free(msg);

                try buf.appendSlice(allocator, "{\"ruleId\":\"cognitive-complexity\",\"message\":{\"text\":");
                try appendJsonEscaped(&buf, allocator, msg);
                try buf.appendSlice(allocator, "},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
                try appendJsonEscaped(&buf, allocator, item.file);
                try buf.appendSlice(allocator, "},\"region\":{\"startLine\":");
                try buf.print(allocator, "{d}", .{item.line});
                try buf.appendSlice(allocator, ",\"endLine\":");
                try buf.print(allocator, "{d}", .{item.end_line});
                try buf.appendSlice(allocator, "}}}]}");
            }
        }
        try buf.appendSlice(allocator, "]}]}");
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"path\":");
        try appendJsonEscaped(&buf, allocator, path);
        try buf.print(allocator, ",\"threshold\":{d},\"functions\":[", .{threshold});
        for (all_funcs.items, 0..) |item, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"file\":");
            try appendJsonEscaped(&buf, allocator, item.file);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonEscaped(&buf, allocator, item.name);
            try buf.print(allocator, ",\"line\":{d},\"end_line\":{d},\"complexity\":{d}}}", .{
                item.line, item.end_line, item.complexity,
            });
        }
        try buf.print(allocator, "],\"exceeded\":{d}}}", .{exceeded_count});
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
    }

    if (exceeded_count == 0) {
        const text = try std.fmt.allocPrint(allocator, "Cognitive Complexity: {s} - 0 functions exceed threshold {d}.", .{ path, threshold });
        return ToolResult{ .text = text, .is_error = false, .count = 0 };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Cognitive Complexity: {s} - {d} function(s) exceed threshold {d}:\n", .{ path, exceeded_count, threshold });
    for (all_funcs.items) |item| {
        if (item.complexity >= threshold) {
            try buf.print(allocator, "  {s}:{d} function '{s}' (lines {d}-{d}): score {d} (threshold {d})\n", .{
                item.file,
                item.line,
                item.name,
                item.line,
                item.end_line,
                item.complexity,
                threshold,
            });
        }
    }
    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
}

const CustomRuleFinding = struct {
    file: []const u8,
    rule: []const u8,
    line: u32,
    column: u32,
    message: []const u8,

    pub fn deinit(self: CustomRuleFinding, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.rule);
        allocator.free(self.message);
    }
};

fn isRegexMeta(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '.', '*', '+', '?', '^', '$', '|', '\\' => true,
        else => false,
    };
}

fn matchesPattern(line: []const u8, pattern: []const u8) ?usize {
    if (pattern.len == 0 or line.len == 0) return null;

    var clean_buf: [256]u8 = undefined;
    const needle = if (pattern.len < clean_buf.len) blk: {
        var clean_len: usize = 0;
        var i: usize = 0;
        while (i < pattern.len) {
            if (pattern[i] == '\\' and i + 1 < pattern.len and isRegexMeta(pattern[i + 1])) {
                clean_buf[clean_len] = pattern[i + 1];
                clean_len += 1;
                i += 2;
            } else {
                clean_buf[clean_len] = pattern[i];
                clean_len += 1;
                i += 1;
            }
        }
        break :blk clean_buf[0..clean_len];
    } else pattern;

    var in_sq = false;
    var in_dq = false;
    var in_bt = false;
    var in_block = false;

    var i: usize = 0;
    while (i < line.len) {
        if (!in_sq and !in_dq and !in_bt and !in_block) {
            if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                break;
            }
            if (line[i] == '#') {
                break;
            }
            if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                in_block = true;
                i += 2;
                continue;
            }
            if (line[i] == '"') {
                in_dq = true;
                i += 1;
                continue;
            }
            if (line[i] == '\'') {
                in_sq = true;
                i += 1;
                continue;
            }
            if (line[i] == '`') {
                in_bt = true;
                i += 1;
                continue;
            }

            if (needle.len > 0 and std.mem.startsWith(u8, line[i..], needle)) {
                return i;
            }
            if (std.mem.startsWith(u8, line[i..], pattern)) {
                return i;
            }

            i += 1;
            continue;
        }

        if (in_block) {
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                in_block = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        if (in_dq) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 2;
                continue;
            }
            if (line[i] == '"') {
                in_dq = false;
            }
            i += 1;
            continue;
        }

        if (in_sq) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 2;
                continue;
            }
            if (line[i] == '\'') {
                in_sq = false;
            }
            i += 1;
            continue;
        }

        if (in_bt) {
            if (line[i] == '`') {
                in_bt = false;
            }
            i += 1;
            continue;
        }
    }

    return null;
}

fn executeEvaluateRules(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const rules_path = getStringArg(args, "rules");
    if (rules_path == null) {
        return executeAuditNoise(allocator, args);
    }

    const path = getStringArg(args, "path") orelse ".";
    const format = getStringArg(args, "format") orelse "text";

    const rules_file_path = rules_path.?;
    const rules_content = runner.readFileAlloc(allocator, rules_file_path) catch {
        const text = try std.fmt.allocPrint(allocator, "Error: rules file not found: {s}", .{rules_file_path});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer allocator.free(rules_content);

    var parsed_rules = std.json.parseFromSlice(std.json.Value, allocator, rules_content, .{}) catch {
        const text = try std.fmt.allocPrint(allocator, "Error: failed to parse rules JSON from {s}", .{rules_file_path});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer parsed_rules.deinit();

    const rules_array: []const std.json.Value = switch (parsed_rules.value) {
        .array => |arr| arr.items,
        .object => |obj| if (obj.get("rules")) |r| (if (r == .array) r.array.items else &.{}) else &.{},
        else => &.{},
    };

    var files_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (files_list.items) |f| allocator.free(f);
        files_list.deinit(allocator);
    }
    try collectSourceFiles(allocator, path, &files_list);

    var all_findings: std.ArrayList(CustomRuleFinding) = .empty;
    defer {
        for (all_findings.items) |item| item.deinit(allocator);
        all_findings.deinit(allocator);
    }

    for (files_list.items) |file_path| {
        const content = runner.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        for (rules_array) |rule_val| {
            if (rule_val != .object) continue;
            const robj = rule_val.object;

            if (robj.get("languages")) |langs_val| {
                if (langs_val == .array) {
                    var matches_lang = false;
                    for (langs_val.array.items) |l_item| {
                        if (l_item == .string) {
                            if (std.mem.endsWith(u8, file_path, l_item.string)) {
                                matches_lang = true;
                                break;
                            }
                        }
                    }
                    if (!matches_lang) continue;
                }
            }

            const rule_id = if (robj.get("id")) |id_v| (if (id_v == .string) id_v.string else "custom-rule") else "custom-rule";
            const rule_pattern = if (robj.get("pattern")) |p_v| (if (p_v == .string) p_v.string else "") else "";
            if (rule_pattern.len == 0) continue;
            const rule_msg = if (robj.get("message")) |m_v| (if (m_v == .string) m_v.string else "Custom rule violation") else "Custom rule violation";

            var line_no: u32 = 1;
            var line_start: usize = 0;
            var i: usize = 0;
            while (i <= content.len) : (i += 1) {
                if (i == content.len or content[i] == '\n') {
                    const line = content[line_start..i];
                    if (matchesPattern(line, rule_pattern)) |match_idx| {
                        try all_findings.append(allocator, .{
                            .file = try allocator.dupe(u8, file_path),
                            .rule = try allocator.dupe(u8, rule_id),
                            .line = line_no,
                            .column = @intCast(match_idx + 1),
                            .message = try allocator.dupe(u8, rule_msg),
                        });
                    }
                    line_no += 1;
                    line_start = i + 1;
                }
            }
        }
    }

    if (compact.isCompact(format)) {
        if (all_findings.items.len == 0) {
            const text = try compact.formatNoise(allocator, path, 1, 1, "evaluate_rules", "0 rule violations detected.");
            return ToolResult{ .text = text, .is_error = false, .count = 0 };
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (all_findings.items) |item| {
            const line = try compact.formatNoise(allocator, item.file, item.line, item.column, item.rule, item.message);
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"path\":");
        try appendJsonEscaped(&buf, allocator, path);
        try buf.appendSlice(allocator, ",\"violations\":[");
        for (all_findings.items, 0..) |item, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"file\":");
            try appendJsonEscaped(&buf, allocator, item.file);
            try buf.appendSlice(allocator, ",\"rule\":");
            try appendJsonEscaped(&buf, allocator, item.rule);
            try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{
                item.line,
                item.column,
            });
            try appendJsonEscaped(&buf, allocator, item.message);
            try buf.append(allocator, '}');
        }
        try buf.print(allocator, "],\"total_noise\":{d}}}", .{all_findings.items.len});
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
    }

    if (all_findings.items.len == 0) {
        const text = try std.fmt.allocPrint(allocator, "Custom Rules Audit: {s} - 0 violations found.", .{path});
        return ToolResult{ .text = text, .is_error = false, .count = 0 };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Custom Rules Audit: {s} - {d} violation(s) found:\n", .{ path, all_findings.items.len });
    for (all_findings.items) |item| {
        try buf.print(allocator, "  {s}:{d}:{d} [{s}] {s}\n", .{
            item.file,
            item.line,
            item.column,
            item.rule,
            item.message,
        });
    }
    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = all_findings.items.len };
}

test "mcp server request handling" {
    const allocator = std.testing.allocator;

    const init_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const init_resp = (try @import("server.zig").handleJsonRpcLine(allocator, init_req)).?;
    defer allocator.free(init_resp);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"protocolVersion\":\"2024-11-05\"") != null);

    const tools_req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}";
    const tools_resp = (try @import("server.zig").handleJsonRpcLine(allocator, tools_req)).?;
    defer allocator.free(tools_resp);
    try std.testing.expect(std.mem.indexOf(u8, tools_resp, "inspect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_resp, "audit_noise") != null);

    const call_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"audit_noise\",\"arguments\":{\"path\":\"src/\"}}}";
    const call_resp = (try @import("server.zig").handleJsonRpcLine(allocator, call_req)).?;
    defer allocator.free(call_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_resp, "Zero-Noise Audit") != null);

    const call_compact = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"complexity\",\"arguments\":{\"path\":\"test.zig\",\"format\":\"compact\"}}}";
    const comp_resp = (try @import("server.zig").handleJsonRpcLine(allocator, call_compact)).?;
    defer allocator.free(comp_resp);
    try std.testing.expect(std.mem.indexOf(u8, comp_resp, "[COMPLEXITY]") != null);

    const unknown_req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"non_existent\"}";
    const unk_resp = (try @import("server.zig").handleJsonRpcLine(allocator, unknown_req)).?;
    defer allocator.free(unk_resp);
    try std.testing.expect(std.mem.indexOf(u8, unk_resp, "-32601") != null);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    try collectSourceFiles(allocator, "tests/fixtures/dirty", &files);
    try std.testing.expect(files.items.len == 5);
}

test "server input validation: negative integers do not panic" {
    const allocator = std.testing.allocator;

    const req = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"complexity\",\"arguments\":{\"path\":\"tests/fixtures/dirty/noisy_go.go\",\"threshold\":-5,\"format\":\"json\"}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("result") != null);
}

test "inspect_evidence returns error on missing file and computes blast risk on existing file" {
    const allocator = std.testing.allocator;

    const bad_req = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_evidence\",\"arguments\":{\"path\":\"nonexistent_file_xyz123.go\"}}}";
    const bad_resp = (try @import("server.zig").handleJsonRpcLine(allocator, bad_req)).?;
    defer allocator.free(bad_resp);

    var bad_parsed = try std.json.parseFromSlice(std.json.Value, allocator, bad_resp, .{});
    defer bad_parsed.deinit();
    const result_obj = bad_parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(true, result_obj.get("isError").?.bool);

    const good_req = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_evidence\",\"arguments\":{\"path\":\"tests/fixtures/dirty/noisy_go.go\",\"page\":1,\"page_size\":5}}}";
    const good_resp = (try @import("server.zig").handleJsonRpcLine(allocator, good_req)).?;
    defer allocator.free(good_resp);

    var good_parsed = try std.json.parseFromSlice(std.json.Value, allocator, good_resp, .{});
    defer good_parsed.deinit();
    const good_result = good_parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, good_result.get("isError").?.bool);
    const content_text = good_result.get("content").?.array.items[0].object.get("text").?.string;
    var inner_json = try std.json.parseFromSlice(std.json.Value, allocator, content_text, .{});
    defer inner_json.deinit();
    try std.testing.expect(inner_json.value.object.get("metrics").?.object.get("blast_radius_risk") != null);
    try std.testing.expect(inner_json.value.object.get("metrics").?.object.get("priority_score") != null);
    try std.testing.expectEqual(@as(i64, 1), inner_json.value.object.get("page").?.integer);
    try std.testing.expectEqual(@as(i64, 5), inner_json.value.object.get("page_size").?.integer);
}

test "evaluate_rules with custom declarative rules" {
    const allocator = std.testing.allocator;

    const rules_path = "tests/test_custom_rules.json";
    const rules_content =
        \\[
        \\  {
        \\    "id": "no-println",
        \\    "pattern": "println",
        \\    "message": "Use logger instead of println",
        \\    "languages": [".go"]
        \\  }
        \\]
    ;
    const io = std.Options.debug_io;
    const f = try std.Io.Dir.cwd().createFile(io, rules_path, .{});
    try f.writeStreamingAll(io, rules_content);
    f.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, rules_path) catch {};

    const req = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"evaluate_rules\",\"arguments\":{\"path\":\"tests/fixtures/dirty/noisy_go.go\",\"rules\":\"tests/test_custom_rules.json\",\"format\":\"json\"}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    const result_obj = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result_obj.get("isError").?.bool);
    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, content_text, "no-println") != null);
}

test "json escaping for path and symbols" {
    const allocator = std.testing.allocator;

    const req = "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"blast_radius\",\"arguments\":{\"symbol\":\"Sym\\\"Bol\\\\Test\",\"format\":\"json\"}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    const result_obj = parsed.value.object.get("result").?.object;
    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try std.json.parseFromSlice(std.json.Value, allocator, content_text, .{});
    defer inner.deinit();
    try std.testing.expectEqualStrings("Sym\"Bol\\Test", inner.value.object.get("symbol").?.string);
}

test "safe_refactor max_blast_risk enforcement" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    // Create two files: test_blast_a.go defines SharedItem, test_blast_b.go uses it -> medium risk
    const file_a = "tests/test_blast_a.go";
    const file_b = "tests/test_blast_b.go";

    const f_a = try std.Io.Dir.cwd().createFile(io, file_a, .{});
    try f_a.writeStreamingAll(io, "package main\n\nfunc SharedItem() bool {\n  return true\n}\n");
    f_a.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_a) catch {};

    const f_b = try std.Io.Dir.cwd().createFile(io, file_b, .{});
    try f_b.writeStreamingAll(io, "package main\n\nfunc Other() {\n  SharedItem()\n}\n");
    f_b.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_b) catch {};

    // 1. Calling safe_refactor with max_blast_risk="low" should abort because risk is medium
    const abort_req = "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_blast_a.go\",\"root\":\"tests\",\"max_blast_risk\":\"low\",\"format\":\"json\"}}}";
    const abort_resp = (try @import("server.zig").handleJsonRpcLine(allocator, abort_req)).?;
    defer allocator.free(abort_resp);

    var parsed_abort = try std.json.parseFromSlice(std.json.Value, allocator, abort_resp, .{});
    defer parsed_abort.deinit();
    const abort_result = parsed_abort.value.object.get("result").?.object;
    try std.testing.expectEqual(true, abort_result.get("isError").?.bool);
    const abort_text = abort_result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, abort_text, "exceeds maximum allowed risk") != null);

    // 2. Calling with force=true should bypass the gate
    const force_req = "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_blast_a.go\",\"root\":\"tests\",\"max_blast_risk\":\"low\",\"force\":true,\"format\":\"json\"}}}";
    const force_resp = (try @import("server.zig").handleJsonRpcLine(allocator, force_req)).?;
    defer allocator.free(force_resp);

    var parsed_force = try std.json.parseFromSlice(std.json.Value, allocator, force_resp, .{});
    defer parsed_force.deinit();
    const force_result = parsed_force.value.object.get("result").?.object;
    try std.testing.expectEqual(false, force_result.get("isError").?.bool);
}

test "executeAuditNoise format=evidence and config file parsing" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    const cfg_path = "tests/test_noise_cfg.json";
    const cfg_content = "{\"max_nesting\":1,\"max_closure_len\":30,\"ignore_patterns\":[\"ignore_me_*.go\"]}";
    const cf = try std.Io.Dir.cwd().createFile(io, cfg_path, .{});
    try cf.writeStreamingAll(io, cfg_content);
    cf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    const req = "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"audit_noise\",\"arguments\":{\"path\":\"tests/fixtures/dirty/noisy_go.go\",\"format\":\"evidence\",\"config\":\"tests/test_noise_cfg.json\"}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    const result_obj = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result_obj.get("isError").?.bool);

    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try std.json.parseFromSlice(std.json.Value, allocator, content_text, .{});
    defer inner.deinit();
    try std.testing.expect(inner.value.object.get("state_lock_sha256") != null);
    try std.testing.expect(inner.value.object.get("metrics") != null);
}

test "executeComplexity format=sarif output" {
    const allocator = std.testing.allocator;

    const req = "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"complexity\",\"arguments\":{\"path\":\"tests/fixtures/dirty/noisy_go.go\",\"format\":\"sarif\",\"threshold\":1}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    const result_obj = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result_obj.get("isError").?.bool);

    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    var sarif = try std.json.parseFromSlice(std.json.Value, allocator, content_text, .{});
    defer sarif.deinit();
    try std.testing.expectEqualStrings("2.1.0", sarif.value.object.get("version").?.string);
    try std.testing.expect(sarif.value.object.get("runs") != null);
    const runs = sarif.value.object.get("runs").?.array;
    try std.testing.expect(runs.items.len > 0);
    const results = runs.items[0].object.get("results").?.array;
    try std.testing.expect(results.items.len > 0);
}

test "executeEvaluateRules ignores comments and string literals" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    const src_path = "tests/test_comment_string_sample.go";
    const src_content =
        \\package main
        \\// println("in single line comment")
        \\/* println("in block comment") */
        \\func Foo() {
        \\    msg := "println inside string literal"
        \\    _ = msg
        \\}
    ;
    const sf = try std.Io.Dir.cwd().createFile(io, src_path, .{});
    try sf.writeStreamingAll(io, src_content);
    sf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, src_path) catch {};

    const rules_path = "tests/test_eval_rules.json";
    const rules_content =
        \\[
        \\  {
        \\    "id": "no-println",
        \\    "pattern": "println",
        \\    "message": "Do not use println",
        \\    "languages": [".go"]
        \\  }
        \\]
    ;
    const rf = try std.Io.Dir.cwd().createFile(io, rules_path, .{});
    try rf.writeStreamingAll(io, rules_content);
    rf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, rules_path) catch {};

    const req = "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"evaluate_rules\",\"arguments\":{\"path\":\"tests/test_comment_string_sample.go\",\"rules\":\"tests/test_eval_rules.json\",\"format\":\"json\"}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    const result_obj = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result_obj.get("isError").?.bool);

    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try std.json.parseFromSlice(std.json.Value, allocator, content_text, .{});
    defer inner.deinit();
    const violations = inner.value.object.get("violations").?.array;
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "executeSafeRefactor with candidate_content and patch_file and ledger integration" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    defer {
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db") catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db-wal") catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db-shm") catch {};
        std.Io.Dir.cwd().deleteDir(io, "tests/.zero-noise") catch {};
    }

    const file_path = "tests/test_safe_refactor_mcp.go";
    const initial_content = "package main\n\nfunc Sample() int {\n    return 1\n}\n";
    const sf = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    try sf.writeStreamingAll(io, initial_content);
    sf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    // 1. Refactor via candidate_content
    const cand_content = "package main\n\nfunc Sample() int {\n    return 2\n}\n";
    const req1 = "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_safe_refactor_mcp.go\",\"root\":\"tests\",\"candidate_content\":\"" ++ "package main\\n\\nfunc Sample() int {\\n    return 2\\n}\\n" ++ "\",\"format\":\"json\"}}}";
    const resp1 = (try @import("server.zig").handleJsonRpcLine(allocator, req1)).?;
    defer allocator.free(resp1);

    var parsed1 = try std.json.parseFromSlice(std.json.Value, allocator, resp1, .{});
    defer parsed1.deinit();
    const result1 = parsed1.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result1.get("isError").?.bool);

    const content_after1 = try runner.readFileAlloc(allocator, file_path);
    defer allocator.free(content_after1);
    try std.testing.expectEqualStrings(cand_content, content_after1);

    // 2. Refactor via patch_file
    const patch_path = "tests/test_safe_refactor_mcp.patch";
    const patch_content =
        \\--- a/tests/test_safe_refactor_mcp.go
        \\+++ b/tests/test_safe_refactor_mcp.go
        \\@@ -4,1 +4,1 @@
        \\-    return 2
        \\+    return 3
        \\
    ;
    const pf = try std.Io.Dir.cwd().createFile(io, patch_path, .{});
    try pf.writeStreamingAll(io, patch_content);
    pf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, patch_path) catch {};

    const req2 = "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_safe_refactor_mcp.go\",\"root\":\"tests\",\"patch_file\":\"tests/test_safe_refactor_mcp.patch\",\"format\":\"json\"}}}";
    const resp2 = (try @import("server.zig").handleJsonRpcLine(allocator, req2)).?;
    defer allocator.free(resp2);

    var parsed2 = try std.json.parseFromSlice(std.json.Value, allocator, resp2, .{});
    defer parsed2.deinit();
    const result2 = parsed2.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result2.get("isError").?.bool);

    const content_after2 = try runner.readFileAlloc(allocator, file_path);
    defer allocator.free(content_after2);
    try std.testing.expectEqualStrings("package main\n\nfunc Sample() int {\n    return 3\n}\n", content_after2);
}



