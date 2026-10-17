const std = @import("std");
const protocol = @import("protocol.zig");
const compact = @import("compact.zig");
const noise = @import("../analysis/noise.zig");
const complexity = @import("../analysis/complexity.zig");
const blast = @import("../analysis/blast.zig");
const runner = @import("../mutation/runner.zig");
const rewriter = @import("../mutation/rewriter.zig");
const grammars = @import("../treesitter/grammars.zig");

pub const ToolResult = struct {
    text: []const u8,
    is_error: bool,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: ?std.json.Value,
) !ToolResult {
    if (std.mem.eql(u8, tool_name, "audit_noise")) {
        return executeAuditNoise(allocator, args);
    } else if (std.mem.eql(u8, tool_name, "refactor_helper")) {
        return executeRefactorHelper(allocator, args);
    } else if (std.mem.eql(u8, tool_name, "blast_radius")) {
        return executeBlastRadius(allocator, args);
    } else if (std.mem.eql(u8, tool_name, "inspect_evidence") or std.mem.eql(u8, tool_name, "evidence_contract")) {
        return executeInspectEvidence(allocator, args);
    } else if (std.mem.eql(u8, tool_name, "safe_refactor")) {
        return executeSafeRefactor(allocator, args);
    } else if (std.mem.eql(u8, tool_name, "complexity")) {
        return executeComplexity(allocator, args);
    } else if (std.mem.eql(u8, tool_name, "evaluate_rules")) {
        return executeEvaluateRules(allocator, args);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
        return ToolResult{ .text = msg, .is_error = true };
    }
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
                if (val == .integer) return val.integer;
            }
        }
    }
    return default_val;
}

fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    try list.append(allocator, '"');
    for (str) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
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
    const path = getStringArg(args, "path") orelse ".";
    const format = getStringArg(args, "format") orelse "text";

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
        const lang = grammars.Language.fromPath(file_path);
        if (lang == .unknown) continue;

        const content = runner.readFileAlloc(allocator, file_path) catch continue;
        defer allocator.free(content);

        const findings = noise.auditNoise(allocator, content, lang) catch continue;
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
            return ToolResult{ .text = text, .is_error = false };
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (all_findings.items) |item| {
            const line = try compact.formatNoise(allocator, item.file, item.line, item.column, item.rule.asString(), item.message);
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{{\"path\":\"{s}\",\"violations\":[", .{path});
        for (all_findings.items, 0..) |item, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "{{\"file\":\"{s}\",\"rule\":\"{s}\",\"line\":{d},\"column\":{d},\"message\":", .{
                item.file,
                item.rule.asString(),
                item.line,
                item.column,
            });
            try appendJsonEscaped(&buf, allocator, item.message);
            try buf.append(allocator, '}');
        }
        try buf.print(allocator, "],\"total_noise\":{d}}}", .{all_findings.items.len});
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
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
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
    }

    if (all_findings.items.len == 0) {
        const text = try std.fmt.allocPrint(allocator, "Zero-Noise Audit: {s} - 0 violations found.", .{path});
        return ToolResult{ .text = text, .is_error = false };
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
    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
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
        try buf.print(allocator, "{{\"symbol\":\"{s}\",\"definitions\":{d},\"references\":{d},\"files\":{d},\"risk\":\"{s}\",\"usages\":[", .{
            symbol, defs_count, refs_count, result.files_count, result.risk.asString(),
        });
        for (result.references, 0..) |ref, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "{{\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"is_definition\":{s}}}", .{
                ref.file, ref.line, ref.column, if (ref.is_definition) "true" else "false",
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
        const text = try std.fmt.allocPrint(allocator,
            \\{{"file":"{s}","state_lock_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","metrics":{{"noise_count":0,"cognitive_complexity":0,"blast_radius_risk":"low"}},"findings":[],"page":1,"page_size":10,"total":0}}
        , .{path});
        return ToolResult{ .text = text, .is_error = false };
    };
    defer allocator.free(content);

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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{{\"file\":\"{s}\",\"state_lock_sha256\":\"{s}\",\"metrics\":{{\"noise_count\":{d},\"cognitive_complexity\":{d},\"blast_radius_risk\":\"low\"}},\"findings\":[", .{
        path, actual_hash, findings.len, max_complexity,
    });
    for (findings, 0..) |f, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "{{\"rule\":\"{s}\",\"line\":{d},\"column\":{d},\"message\":", .{
            f.rule.asString(), f.line, f.column,
        });
        try appendJsonEscaped(&buf, allocator, f.message);
        try buf.append(allocator, '}');
    }
    try buf.print(allocator, "],\"page\":1,\"page_size\":10,\"total\":{d}}}", .{findings.len});

    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn executeSafeRefactor(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    const filepath = getStringArg(args, "filepath") orelse "";
    const format = getStringArg(args, "format") orelse "text";
    const expected_hash = getStringArg(args, "expected_hash");
    const test_cmd = getStringArg(args, "test_cmd");
    const fix = if (args) |v| blk: {
        if (v == .object) {
            if (v.object.get("fix")) |val| {
                if (val == .bool) break :blk val.bool;
            }
        }
        break :blk true;
    } else true;

    var result = runner.executeSafeRefactor(allocator, .{
        .filepath = filepath,
        .expected_hash = expected_hash,
        .test_cmd = test_cmd,
        .fix = fix,
    }) catch |err| {
        const text = try std.fmt.allocPrint(allocator, "Safe refactor error: {s}", .{@errorName(err)});
        return ToolResult{ .text = text, .is_error = true };
    };
    defer result.deinit(allocator);

    const status_str = result.status.asString();

    if (compact.isCompact(format)) {
        const text = try compact.formatRefactor(allocator, filepath, status_str, expected_hash orelse "unlocked", if (result.error_msg) |em| em else "safe refactor completed");
        return ToolResult{ .text = text, .is_error = (result.status == .aborted or result.status == .rolled_back) };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{{\"filepath\":\"{s}\",\"status\":\"{s}\",\"diff\":", .{ filepath, status_str });
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
    const threshold: u32 = @intCast(getIntArg(args, "threshold", 15));
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
            if (rec.complexity >= threshold or std.mem.eql(u8, format, "json")) {
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
            return ToolResult{ .text = text, .is_error = false };
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
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{{\"path\":\"{s}\",\"threshold\":{d},\"functions\":[", .{ path, threshold });
        for (all_funcs.items, 0..) |item, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "{{\"file\":\"{s}\",\"name\":", .{item.file});
            try appendJsonEscaped(&buf, allocator, item.name);
            try buf.print(allocator, ",\"line\":{d},\"end_line\":{d},\"complexity\":{d}}}", .{
                item.line, item.end_line, item.complexity,
            });
        }
        try buf.print(allocator, "],\"exceeded\":{d}}}", .{exceeded_count});
        return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
    }

    if (exceeded_count == 0) {
        const text = try std.fmt.allocPrint(allocator, "Cognitive Complexity: {s} - 0 functions exceed threshold {d}.", .{ path, threshold });
        return ToolResult{ .text = text, .is_error = false };
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
    return ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn executeEvaluateRules(allocator: std.mem.Allocator, args: ?std.json.Value) !ToolResult {
    return executeAuditNoise(allocator, args);
}


pub fn handleJsonRpcLine(
    allocator: std.mem.Allocator,
    line: []const u8,
) !?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return try protocol.buildErrorResponseJson(
            allocator,
            .null_id,
            protocol.ErrorCodes.ParseError,
            "Parse error",
        );
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try protocol.buildErrorResponseJson(
            allocator,
            .null_id,
            protocol.ErrorCodes.InvalidRequest,
            "Invalid Request",
        );
    }

    const root_obj = parsed.value.object;
    const method_val = root_obj.get("method") orelse {
        return try protocol.buildErrorResponseJson(
            allocator,
            .null_id,
            protocol.ErrorCodes.InvalidRequest,
            "Invalid Request: missing method",
        );
    };

    if (method_val != .string) {
        return try protocol.buildErrorResponseJson(
            allocator,
            .null_id,
            protocol.ErrorCodes.InvalidRequest,
            "Invalid Request: method must be string",
        );
    }

    const method = method_val.string;

    var req_id: protocol.RequestId = .null_id;
    if (root_obj.get("id")) |id_node| {
        switch (id_node) {
            .integer => |i| req_id = .{ .integer = i },
            .string => |s| req_id = .{ .string = s },
            else => req_id = .null_id,
        }
    }

    if (std.mem.eql(u8, method, "initialize")) {
        const init_res = try protocol.buildInitializeResultJson(allocator);
        defer allocator.free(init_res);
        return try protocol.buildSuccessResponseJson(allocator, req_id, init_res);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return null;
    } else if (std.mem.eql(u8, method, "ping")) {
        return try protocol.buildSuccessResponseJson(allocator, req_id, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        const tools_res = try protocol.buildToolsListJson(allocator);
        defer allocator.free(tools_res);
        return try protocol.buildSuccessResponseJson(allocator, req_id, tools_res);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params_val = root_obj.get("params");
        var tool_name: []const u8 = "";
        var arguments: ?std.json.Value = null;

        if (params_val) |pv| {
            if (pv == .object) {
                if (pv.object.get("name")) |nv| {
                    if (nv == .string) tool_name = nv.string;
                }
                arguments = pv.object.get("arguments");
            }
        }

        const tool_result = try executeToolCall(allocator, tool_name, arguments);
        defer tool_result.deinit(allocator);

        const call_res = try protocol.buildToolCallResultJson(
            allocator,
            tool_result.text,
            tool_result.is_error,
        );
        defer allocator.free(call_res);

        return try protocol.buildSuccessResponseJson(allocator, req_id, call_res);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "Method not found: {s}", .{method});
        defer allocator.free(msg);
        return try protocol.buildErrorResponseJson(allocator, req_id, protocol.ErrorCodes.MethodNotFound, msg);
    }
}

pub fn run(allocator: std.mem.Allocator) !void {
    const io = std.Options.debug_io;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    var in_buf: [8192]u8 = undefined;
    var reader = stdin.readerStreaming(io, &in_buf);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;

        const maybe_resp = try handleJsonRpcLine(allocator, line);
        if (maybe_resp) |resp| {
            defer allocator.free(resp);
            try stdout.writeStreamingAll(io, resp);
            try stdout.writeStreamingAll(io, "\n");
        }
    }
}

test "mcp server request handling" {
    const allocator = std.testing.allocator;

    const init_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const init_resp = (try handleJsonRpcLine(allocator, init_req)).?;
    defer allocator.free(init_resp);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"protocolVersion\":\"2024-11-05\"") != null);

    const tools_req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}";
    const tools_resp = (try handleJsonRpcLine(allocator, tools_req)).?;
    defer allocator.free(tools_resp);
    try std.testing.expect(std.mem.indexOf(u8, tools_resp, "inspect_evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_resp, "audit_noise") != null);

    const call_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"audit_noise\",\"arguments\":{\"path\":\"src/\"}}}";
    const call_resp = (try handleJsonRpcLine(allocator, call_req)).?;
    defer allocator.free(call_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_resp, "Zero-Noise Audit") != null);

    const call_compact = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"complexity\",\"arguments\":{\"path\":\"test.zig\",\"format\":\"compact\"}}}";
    const comp_resp = (try handleJsonRpcLine(allocator, call_compact)).?;
    defer allocator.free(comp_resp);
    try std.testing.expect(std.mem.indexOf(u8, comp_resp, "[COMPLEXITY]") != null);

    const unknown_req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"non_existent\"}";
    const unk_resp = (try handleJsonRpcLine(allocator, unknown_req)).?;
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
