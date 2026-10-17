const std = @import("std");
const common = @import("common.zig");
const compact = @import("compact.zig");

const JSON_PATH = "{\"path\":";
const JSON_FILE = "{\"file\":";
const JSON_RULE = ",\"rule\":";
const JSON_LINE = ",\"line\":";
const JSON_COLUMN = ",\"column\":";
const JSON_MESSAGE = ",\"message\":";

pub fn auditNoise(
    allocator: std.mem.Allocator,
    path: []const u8,
    findings: anytype,
    format: []const u8,
) !common.ToolResult {
    const items = if (@hasField(@TypeOf(findings), "items")) findings.items else findings;

    if (compact.isCompact(format)) {
        return formatAuditCompact(allocator, path, items);
    }
    if (std.mem.eql(u8, format, "json")) {
        return formatAuditJson(allocator, path, items);
    }
    if (std.mem.eql(u8, format, "sarif")) {
        return formatAuditSarif(allocator, path, items);
    }
    return formatAuditText(allocator, path, items);
}

fn formatAuditCompact(allocator: std.mem.Allocator, path: []const u8, items: anytype) !common.ToolResult {
    if (items.len == 0) {
        const text = try compact.formatNoise(allocator, path, 1, 1, "audit_noise", "0 structural noise violations detected.");
        return common.ToolResult{ .text = text, .is_error = false, .count = 0 };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (items) |item| {
        const line = try compact.formatNoise(allocator, item.file, item.line, item.column, item.rule.asString(), item.message);
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
}

fn formatAuditJson(allocator: std.mem.Allocator, path: []const u8, items: anytype) !common.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"path\":");
    try common.appendJsonEscaped(&buf, allocator, path);
    try buf.appendSlice(allocator, ",\"violations\":[");
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"file\":");
        try common.appendJsonEscaped(&buf, allocator, item.file);
        try buf.appendSlice(allocator, ",\"rule\":");
        try common.appendJsonEscaped(&buf, allocator, item.rule.asString());
        try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{
            item.line,
            item.column,
        });
        try common.appendJsonEscaped(&buf, allocator, item.message);
        try buf.append(allocator, '}');
    }
    try buf.print(allocator, "],\"total_noise\":{d}}}", .{items.len});
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
}

fn formatAuditSarif(allocator: std.mem.Allocator, path: []const u8, items: anytype) !common.ToolResult {
    _ = path;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"zero-noise\",\"version\":\"0.1.0\"}},\"results\":[");
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"ruleId\":");
        try common.appendJsonEscaped(&buf, allocator, item.rule.asString());
        try buf.appendSlice(allocator, ",\"message\":{\"text\":");
        try common.appendJsonEscaped(&buf, allocator, item.message);
        try buf.appendSlice(allocator, "},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
        try common.appendJsonEscaped(&buf, allocator, item.file);
        try buf.appendSlice(allocator, "},\"region\":{\"startLine\":");
        try buf.print(allocator, "{d}", .{item.line});
        try buf.appendSlice(allocator, ",\"startColumn\":");
        try buf.print(allocator, "{d}", .{item.column});
        try buf.appendSlice(allocator, "}}}]}");
    }
    try buf.appendSlice(allocator, "]}]}");
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
}

fn formatAuditText(allocator: std.mem.Allocator, path: []const u8, items: anytype) !common.ToolResult {
    if (items.len == 0) {
        const text = try std.fmt.allocPrint(allocator, "Zero-Noise Audit: {s} - 0 violations found.", .{path});
        return common.ToolResult{ .text = text, .is_error = false, .count = 0 };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Zero-Noise Audit: {s} - {d} structural noise violation(s) found:\n", .{ path, items.len });
    for (items) |item| {
        try buf.print(allocator, "  {s}:{d}:{d} [{s}] {s}\n", .{
            item.file,
            item.line,
            item.column,
            item.rule.asString(),
            item.message,
        });
    }
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
}
pub fn complexity(
    allocator: std.mem.Allocator,
    path: []const u8,
    threshold: u32,
    findings: anytype,
    exceeded_count: usize,
    format: []const u8,
) !common.ToolResult {
    const items = if (@hasField(@TypeOf(findings), "items")) findings.items else findings;

    if (compact.isCompact(format)) {
        return formatComplexityCompact(allocator, path, threshold, items, exceeded_count);
    }
    if (std.mem.eql(u8, format, "sarif")) {
        return formatComplexitySarif(allocator, path, threshold, items, exceeded_count);
    }
    if (std.mem.eql(u8, format, "json")) {
        return formatComplexityJson(allocator, path, threshold, items, exceeded_count);
    }
    return formatComplexityText(allocator, path, threshold, items, exceeded_count);
}

fn formatComplexityCompact(allocator: std.mem.Allocator, path: []const u8, threshold: u32, items: anytype, exceeded_count: usize) !common.ToolResult {
    if (exceeded_count == 0) {
        const text = try compact.formatComplexity(allocator, path, 1, "all_functions", 0, threshold);
        return common.ToolResult{ .text = text, .is_error = false, .count = 0 };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (items) |item| {
        if (item.complexity >= threshold) {
            const line = try compact.formatComplexity(allocator, item.file, item.line, item.name, item.complexity, threshold);
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
    }
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
}

fn formatComplexitySarif(allocator: std.mem.Allocator, path: []const u8, threshold: u32, items: anytype, exceeded_count: usize) !common.ToolResult {
    _ = path;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"zero-noise\",\"version\":\"0.1.0\"}},\"results\":[");
    var first = true;
    for (items) |item| {
        if (item.complexity < threshold) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        const msg = try std.fmt.allocPrint(allocator, "Function '{s}' cognitive complexity {d} exceeds threshold {d}", .{ item.name, item.complexity, threshold });
        defer allocator.free(msg);
        try buf.appendSlice(allocator, "{\"ruleId\":\"cognitive-complexity\",\"message\":{\"text\":");
        try common.appendJsonEscaped(&buf, allocator, msg);
        try buf.appendSlice(allocator, "},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
        try common.appendJsonEscaped(&buf, allocator, item.file);
        try buf.appendSlice(allocator, "},\"region\":{\"startLine\":");
        try buf.print(allocator, "{d}", .{item.line});
        try buf.appendSlice(allocator, ",\"endLine\":");
        try buf.print(allocator, "{d}", .{item.end_line});
        try buf.appendSlice(allocator, "}}}]}");
    }
    try buf.appendSlice(allocator, "]}]}");
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
}

fn formatComplexityJson(allocator: std.mem.Allocator, path: []const u8, threshold: u32, items: anytype, exceeded_count: usize) !common.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"path\":");
    try common.appendJsonEscaped(&buf, allocator, path);
    try buf.print(allocator, ",\"threshold\":{d},\"functions\":[", .{threshold});
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"file\":");
        try common.appendJsonEscaped(&buf, allocator, item.file);
        try buf.appendSlice(allocator, ",\"name\":");
        try common.appendJsonEscaped(&buf, allocator, item.name);
        try buf.print(allocator, ",\"line\":{d},\"end_line\":{d},\"complexity\":{d}}}", .{
            item.line, item.end_line, item.complexity,
        });
    }
    try buf.print(allocator, "],\"exceeded\":{d}}}", .{exceeded_count});
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
}

fn formatComplexityText(allocator: std.mem.Allocator, path: []const u8, threshold: u32, items: anytype, exceeded_count: usize) !common.ToolResult {
    if (exceeded_count == 0) {
        const text = try std.fmt.allocPrint(allocator, "Cognitive Complexity: {s} - 0 functions exceed threshold {d}.", .{ path, threshold });
        return common.ToolResult{ .text = text, .is_error = false, .count = 0 };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Cognitive Complexity: {s} - {d} function(s) exceed threshold {d}:\n", .{ path, exceeded_count, threshold });
    for (items) |item| {
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
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = exceeded_count };
}
pub fn evaluateRules(
    allocator: std.mem.Allocator,
    path: []const u8,
    findings: anytype,
    format: []const u8,
) !common.ToolResult {
    const items = if (@hasField(@TypeOf(findings), "items")) findings.items else findings;

    if (compact.isCompact(format)) {
        if (items.len == 0) {
            const text = try compact.formatNoise(allocator, path, 1, 1, "evaluate_rules", "0 rule violations detected.");
            return common.ToolResult{ .text = text, .is_error = false, .count = 0 };
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (items) |item| {
            const line = try compact.formatNoise(allocator, item.file, item.line, item.column, item.rule, item.message);
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
        return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
    }

    if (std.mem.eql(u8, format, "json")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"path\":");
        try common.appendJsonEscaped(&buf, allocator, path);
        try buf.appendSlice(allocator, ",\"violations\":[");
        try appendEvaluateRulesJsonViolations(&buf, allocator, items);
        try buf.print(allocator, "],\"total_noise\":{d}}}", .{items.len});
        return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
    }

    if (items.len == 0) {
        const text = try std.fmt.allocPrint(allocator, "Custom Rules Audit: {s} - 0 violations found.", .{path});
        return common.ToolResult{ .text = text, .is_error = false, .count = 0 };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Custom Rules Audit: {s} - {d} violation(s) found:\n", .{ path, items.len });
    for (items) |item| {
        try buf.print(allocator, "  {s}:{d}:{d} [{s}] {s}\n", .{
            item.file,
            item.line,
            item.column,
            item.rule,
            item.message,
        });
    }
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false, .count = items.len };
}


pub fn blastRadius(
    allocator: std.mem.Allocator,
    symbol: []const u8,
    defs_count: u32,
    refs_count: u32,
    files_count: u32,
    risk: []const u8,
    refs: anytype,
    format: []const u8,
) !common.ToolResult {
    const items = if (@hasField(@TypeOf(refs), "items")) refs.items else refs;

    if (compact.isCompact(format)) {
        const text = try compact.formatBlast(allocator, symbol, defs_count, refs_count, files_count, risk);
        return common.ToolResult{ .text = text, .is_error = false };
    }
    if (std.mem.eql(u8, format, "json")) {
        return formatBlastJson(allocator, symbol, defs_count, refs_count, files_count, risk, items);
    }
    return formatBlastText(allocator, symbol, defs_count, refs_count, files_count, risk, items);
}

fn formatBlastJson(allocator: std.mem.Allocator, symbol: []const u8, defs_count: u32, refs_count: u32, files_count: u32, risk: []const u8, items: anytype) !common.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"symbol\":");
    try common.appendJsonEscaped(&buf, allocator, symbol);
    try buf.print(allocator, ",\"definitions\":{d},\"references\":{d},\"files\":{d},\"risk\":", .{
        defs_count, refs_count, files_count,
    });
    try common.appendJsonEscaped(&buf, allocator, risk);
    try buf.appendSlice(allocator, ",\"usages\":[");
    for (items, 0..) |ref, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"file\":");
        try common.appendJsonEscaped(&buf, allocator, ref.file);
        try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"is_definition\":{s}}}", .{
            ref.line, ref.column, if (ref.is_definition) "true" else "false",
        });
    }
    try buf.appendSlice(allocator, "]}");
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn formatBlastText(allocator: std.mem.Allocator, symbol: []const u8, defs_count: u32, refs_count: u32, files_count: u32, risk: []const u8, items: anytype) !common.ToolResult {
    const risk_upper = riskUpper(risk);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "Blast Radius for '{s}': Risk level {s} ({d} definition, {d} references across {d} file(s)).\n", .{
        symbol,
        risk_upper,
        defs_count,
        refs_count,
        files_count,
    });
    for (items) |ref| {
        try buf.print(allocator, "  {s}:{d}:{d} [{s}]\n", .{
            ref.file, ref.line, ref.column, if (ref.is_definition) "DEF" else "REF",
        });
    }
    return common.ToolResult{ .text = try buf.toOwnedSlice(allocator), .is_error = false };
}

fn riskUpper(risk: []const u8) []const u8 {
    if (std.mem.eql(u8, risk, "low")) return "LOW";
    if (std.mem.eql(u8, risk, "medium")) return "MEDIUM";
    if (std.mem.eql(u8, risk, "high")) return "HIGH";
    return risk;
}


fn appendEvaluateRulesJsonViolations(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, items: anytype) !void {
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"file\":");
        try common.appendJsonEscaped(buf, allocator, item.file);
        try buf.appendSlice(allocator, ",\"rule\":");
        try common.appendJsonEscaped(buf, allocator, item.rule);
        try buf.print(allocator, ",\"line\":{d},\"column\":{d},\"message\":", .{
            item.line,
            item.column,
        });
        try common.appendJsonEscaped(buf, allocator, item.message);
        try buf.append(allocator, '}');
    }
}
