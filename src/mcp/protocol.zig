const std = @import("std");

pub const PROTOCOL_VERSION = "2024-11-05";
pub const SERVER_NAME = "zero-noise";
pub const SERVER_VERSION = "0.1.0";

pub const ErrorCodes = struct {
    pub const ParseError: i32 = -32700;
    pub const InvalidRequest: i32 = -32600;
    pub const MethodNotFound: i32 = -32601;
    pub const InternalError: i32 = -32603;
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

pub const TOOLS = [_]ToolDefinition{
    .{
        .name = "inspect_evidence",
        .description = "Cross-references noise, cognitive complexity, and blast radius into a prioritized, state-locked Evidence Contract pack.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path of the file to inspect."},"root":{"type":"string","description":"Project root directory (default: .)."},"page":{"type":"integer","description":"Page number for pagination (default: 1)."},"page_size":{"type":"integer","description":"Number of findings per page (default: 10)."}},"required":["path"]}
        ,
    },
    .{
        .name = "audit_noise",
        .description = "Audits files or directories against nesting > 2 levels, long inline closures, raw boolean expressions, and commented code.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative or absolute path of the file or directory to audit."},"format":{"type":"string","enum":["text","json","sarif","evidence","compact"],"description":"Output format: text (default), json, sarif, evidence, or compact."},"config":{"type":"string","description":"Optional path to custom .zero-noise.json configuration file."},"root":{"type":"string","description":"Project root directory (used when format is evidence)."},"page":{"type":"integer","description":"Page number for pagination (used when format is evidence)."},"page_size":{"type":"integer","description":"Number of findings per page (used when format is evidence)."}},"required":["path"]}
        ,
    },
    .{
        .name = "refactor_helper",
        .description = "Detects DRY extraction candidates (repeated literals) and boolean algebraic simplification opportunities.",
        .input_schema_json =
        \\{"type":"object","properties":{"filepath":{"type":"string","description":"Path of the file to analyze."}},"required":["filepath"]}
        ,
    },
    .{
        .name = "complexity",
        .description = "Calculates SonarSource Cognitive Complexity per function.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to file or directory."},"threshold":{"type":"integer","description":"Cognitive complexity threshold (default 15)."},"format":{"type":"string","enum":["text","json","sarif","compact"],"description":"Output format: text (default), json, sarif, or compact."}},"required":["path"]}
        ,
    },
    .{
        .name = "blast_radius",
        .description = "Analyzes symbol usages, definitions, and blast radius risk across a codebase.",
        .input_schema_json =
        \\{"type":"object","properties":{"symbol":{"type":"string","description":"Symbol name to analyze."},"root":{"type":"string","description":"Project root directory (default .)."},"format":{"type":"string","enum":["text","json","compact"],"description":"Output format: text (default), json, or compact."}},"required":["symbol"]}
        ,
    },
    .{
        .name = "safe_refactor",
        .description = "Test-bracketed safe refactoring runner with automatic rollback on failure and state-lock hash protection.",
        .input_schema_json =
        \\{"type":"object","properties":{"filepath":{"type":"string","description":"Path of the file to refactor."},"expected_hash":{"type":"string","description":"Expected SHA-256 state lock hash of target file."},"max_blast_risk":{"type":"string","enum":["low","medium","high"],"description":"Maximum allowed blast radius risk level."},"force":{"type":"boolean","description":"Bypass blast radius gate."},"test_cmd":{"type":"string","description":"Optional test command to run for verification (required for guard and predicate patches)."},"fix":{"type":"boolean","description":"Apply changes; dry run by default. Applying a supplied patch requires an explicit patch_kind."},"patch_file":{"type":"string","description":"Optional path to unified diff patch file to apply."},"patch_content":{"type":"string","description":"Optional unified diff patch content to apply."},"patch_kind":{"type":"string","enum":["guard","predicate","constant","closure","boolean","manual"],"description":"Declared kind of the supplied patch; required when applying one."},"candidate_content":{"type":"string","description":"Optional candidate replacement content."},"format":{"type":"string","enum":["text","json","compact"],"description":"Output format: text (default), json, or compact."}},"required":["filepath"]}
        ,
    },
    .{
        .name = "evaluate_rules",
        .description = "Evaluates declarative linting rules against a target path.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Target file or directory path."},"rules":{"type":"string","description":"Optional path to declarative rules JSON file."},"format":{"type":"string","enum":["text","json","compact"],"description":"Output format: text (default), json, or compact."}},"required":["path"]}
        ,
    },
};

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null_id,

    pub fn format(
        self: RequestId,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(u8),
    ) !void {
        switch (self) {
            .integer => |i| try list.print(allocator, "{d}", .{i}),
            .string => |s| try list.print(allocator, "{f}", .{std.json.fmt(s, .{})}),
            .null_id => try list.appendSlice(allocator, "null"),
        }
    }
};

pub fn buildToolsListJson(allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"tools\":[");
    for (TOOLS, 0..) |t, idx| {
        if (idx > 0) try out.append(allocator, ',');
        try out.print(allocator, "{{\"name\":\"{s}\",\"description\":\"{s}\",\"inputSchema\":{s}}}", .{
            t.name,
            t.description,
            t.input_schema_json,
        });
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn buildInitializeResultJson(allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator,
        \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"{s}","version":"{s}"}}}}
    , .{ PROTOCOL_VERSION, SERVER_NAME, SERVER_VERSION });
    return out.toOwnedSlice(allocator);
}

pub fn buildSuccessResponseJson(
    allocator: std.mem.Allocator,
    id: RequestId,
    result_json: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try id.format(allocator, &out);
    try out.appendSlice(allocator, ",\"result\":");
    try out.appendSlice(allocator, result_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn buildToolCallResultJson(
    allocator: std.mem.Allocator,
    text: []const u8,
    is_error: bool,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");
    try out.print(allocator, "{f}", .{std.json.fmt(text, .{})});
    try out.print(allocator, "}}],\"isError\":{s}}}", .{if (is_error) "true" else "false"});
    return out.toOwnedSlice(allocator);
}

pub fn buildErrorResponseJson(
    allocator: std.mem.Allocator,
    id: RequestId,
    code: i32,
    message: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try id.format(allocator, &out);
    try out.print(allocator, ",\"error\":{{\"code\":{d},\"message\":", .{code});
    try out.print(allocator, "{f}", .{std.json.fmt(message, .{})});
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

test "protocol tools list and initialize" {
    const allocator = std.testing.allocator;

    const init_json = try buildInitializeResultJson(allocator);
    defer allocator.free(init_json);
    try std.testing.expect(std.mem.indexOf(u8, init_json, "zero-noise") != null);

    const tools_json = try buildToolsListJson(allocator);
    defer allocator.free(tools_json);
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "audit_noise") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "safe_refactor") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "inspect_evidence") != null);

    const call_json = try buildToolCallResultJson(allocator, "hello world", false);
    defer allocator.free(call_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, call_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello world", parsed.value.object.get("content").?.array.items[0].object.get("text").?.string);

    const resp = try buildSuccessResponseJson(allocator, .{ .integer = 42 }, "{}");
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{}}", resp);

    const err_resp = try buildErrorResponseJson(allocator, .null_id, ErrorCodes.MethodNotFound, "Not found");
    defer allocator.free(err_resp);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"Not found\"}}", err_resp);
}

test "protocol request id escaping" {
    const allocator = std.testing.allocator;

    const escaped_id = RequestId{ .string = "req_\"1\"_test" };
    const resp = try buildSuccessResponseJson(allocator, escaped_id, "{}");
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("req_\"1\"_test", parsed.value.object.get("id").?.string);
}
