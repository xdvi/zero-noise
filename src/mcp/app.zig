const std = @import("std");
const protocol = @import("protocol.zig");
const compact = @import("compact.zig");
const common = @import("common.zig");
const deps_mod = @import("deps.zig");
const runner = @import("../mutation/runner.zig");
const audit_noise = @import("tools/audit_noise.zig");
const refactor_helper = @import("tools/refactor_helper.zig");
const blast_radius = @import("tools/blast_radius.zig");
const inspect_evidence = @import("tools/inspect_evidence.zig");
const safe_refactor = @import("tools/safe_refactor.zig");
const propose_fixes = @import("tools/propose_fixes.zig");
const complexity = @import("tools/complexity.zig");
const evaluate_rules = @import("tools/evaluate_rules.zig");

pub const ToolResult = common.ToolResult;

pub fn executeToolCallWithDeps(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: ?std.json.Value,
    deps_ptr: *const deps_mod.Deps,
) !ToolResult {
    const ToolHandler = *const fn (std.mem.Allocator, ?std.json.Value, *const deps_mod.Deps) anyerror!ToolResult;
    const ToolEntry = struct { name: []const u8, handler: ToolHandler };
    const tool_table = [_]ToolEntry{
        .{ .name = "audit_noise", .handler = audit_noise.executeAuditNoiseWithDeps },
        .{ .name = "refactor_helper", .handler = refactor_helper.executeRefactorHelperWithDeps },
        .{ .name = "blast_radius", .handler = blast_radius.executeBlastRadiusWithDeps },
        .{ .name = "inspect_evidence", .handler = inspect_evidence.executeInspectEvidenceWithDeps },
        .{ .name = "evidence_contract", .handler = inspect_evidence.executeInspectEvidenceWithDeps },
        .{ .name = "safe_refactor", .handler = safe_refactor.executeSafeRefactorWithDeps },
        .{ .name = "propose_fixes", .handler = propose_fixes.executeProposeFixesWithDeps },
        .{ .name = "complexity", .handler = complexity.executeComplexityWithDeps },
        .{ .name = "evaluate_rules", .handler = evaluate_rules.executeEvaluateRulesWithDeps },
    };
    for (tool_table) |entry| {
        if (std.mem.eql(u8, tool_name, entry.name)) {
            return entry.handler(allocator, args, deps_ptr);
        }
    }
    const msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
    return ToolResult{ .text = msg, .is_error = true };
}

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: ?std.json.Value,
) !ToolResult {
    const default = deps_mod.defaultDeps();
    return executeToolCallWithDeps(allocator, tool_name, args, &default);
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
    try common.collectSourceFiles(allocator, "tests/fixtures/dirty", &files);
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
    const force_req = "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_blast_a.go\",\"root\":\"tests\",\"max_blast_risk\":\"low\",\"force\":true,\"fix\":true,\"patch_kind\":\"manual\",\"format\":\"json\"}}}";
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

test "propose_fixes is dispatched with composed proposals" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    const file_path = "tests/test_propose_fixes_mcp.ts";
    const fixture = "function process(user: User): void {\n  if (user.isActive) {\n    sendEmail(user);\n  }\n}\n";
    const sf = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    try sf.writeStreamingAll(io, fixture);
    sf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    const req = "{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"tools/call\",\"params\":{\"name\":\"propose_fixes\",\"arguments\":{\"path\":\"" ++ file_path ++ "\",\"compose\":true,\"format\":\"json\"}}}";
    const resp = (try @import("server.zig").handleJsonRpcLine(allocator, req)).?;
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();
    const result_obj = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result_obj.get("isError").?.bool);

    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try std.json.parseFromSlice(std.json.Value, allocator, content_text, .{});
    defer inner.deinit();
    try std.testing.expectEqual(@as(i64, 1), inner.value.object.get("total").?.integer);
    const composed = inner.value.object.get("composed").?.object;
    try std.testing.expectEqual(@as(usize, 1), composed.get("applied").?.array.items.len);
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
    const req1 = "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_safe_refactor_mcp.go\",\"root\":\"tests\",\"fix\":true,\"patch_kind\":\"manual\",\"candidate_content\":\"" ++ "package main\\n\\nfunc Sample() int {\\n    return 2\\n}\\n" ++ "\",\"format\":\"json\"}}}";
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

    const req2 = "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"safe_refactor\",\"arguments\":{\"filepath\":\"tests/test_safe_refactor_mcp.go\",\"root\":\"tests\",\"fix\":true,\"patch_kind\":\"manual\",\"patch_file\":\"tests/test_safe_refactor_mcp.patch\",\"format\":\"json\"}}}";
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

const E2E_TS_FIXTURE =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    if (user.hasPaid) {
    \\      sendEmail(user);
    \\    }
    \\  }
    \\}
    \\
    \\function notify(user: User): void {
    \\  if (user.isLoggedIn) {
    \\    logOut(user);
    \\  }
    \\}
    \\
;

const E2E_TS_EXPECTED =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    if (!(user.hasPaid)) { return; }
    \\    sendEmail(user);
    \\  }
    \\}
    \\
    \\function notify(user: User): void {
    \\  if (!(user.isLoggedIn)) { return; }
    \\  logOut(user);
    \\}
    \\
;

const E2E_OVERLAP_FIXTURE =
    \\function process(user: User): void {
    \\  if (user.isActive) {
    \\    log("a_value");
    \\    log("a_value");
    \\    log("a_value");
    \\  }
    \\}
    \\
;

const ToolOutcome = struct {
    text: []u8,
    is_error: bool,

    fn deinit(self: ToolOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn e2eJsonEscaped(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try common.appendJsonEscaped(&buf, allocator, text);
    return buf.toOwnedSlice(allocator);
}

fn e2eToolCall(allocator: std.mem.Allocator, id: u32, tool: []const u8, args_json: []const u8) !ToolOutcome {
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ id, tool, args_json },
    );
    defer allocator.free(request);

    const response = (try @import("server.zig").handleJsonRpcLine(allocator, request)).?;
    defer allocator.free(response);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const result_obj = parsed.value.object.get("result").?.object;
    const content_text = result_obj.get("content").?.array.items[0].object.get("text").?.string;
    return .{
        .text = try allocator.dupe(u8, content_text),
        .is_error = result_obj.get("isError").?.bool,
    };
}

fn e2eProposeArgs(
    allocator: std.mem.Allocator,
    path: []const u8,
    compose: bool,
    include_patches: bool,
) ![]u8 {
    const path_json = try e2eJsonEscaped(allocator, path);
    defer allocator.free(path_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"path\":{s},\"compose\":{s},\"include_patches\":{s},\"format\":\"json\"}}",
        .{ path_json, if (compose) "true" else "false", if (include_patches) "true" else "false" },
    );
}

fn e2eApplyArgs(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    patch_text: []const u8,
    patch_kind: []const u8,
    test_cmd: ?[]const u8,
    expected_hash: ?[]const u8,
) ![]u8 {
    const file_json = try e2eJsonEscaped(allocator, filepath);
    defer allocator.free(file_json);
    const kind_json = try e2eJsonEscaped(allocator, patch_kind);
    defer allocator.free(kind_json);
    const patch_json = try e2eJsonEscaped(allocator, patch_text);
    defer allocator.free(patch_json);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "{{\"filepath\":{s},\"root\":\"tests\",\"fix\":true,\"patch_kind\":{s}", .{ file_json, kind_json });
    if (test_cmd) |cmd| {
        const cmd_json = try e2eJsonEscaped(allocator, cmd);
        defer allocator.free(cmd_json);
        try buf.print(allocator, ",\"test_cmd\":{s}", .{cmd_json});
    }
    if (expected_hash) |hash| {
        const hash_json = try e2eJsonEscaped(allocator, hash);
        defer allocator.free(hash_json);
        try buf.print(allocator, ",\"expected_hash\":{s}", .{hash_json});
    }
    try buf.print(allocator, ",\"patch_content\":{s},\"format\":\"json\"}}", .{patch_json});
    return buf.toOwnedSlice(allocator);
}

/// Parses a propose_fixes JSON result, duplicating the strings the caller
/// needs to outlive the parsed document.
const ProposeOutcome = struct {
    total: i64,
    applied: usize,
    conflicts: usize,
    patch: []u8,
    first_hash: ?[]u8,
    proposals_json: std.json.Parsed(std.json.Value),

    fn deinit(self: *ProposeOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.patch);
        if (self.first_hash) |hash| allocator.free(hash);
        self.proposals_json.deinit();
    }
};

fn e2eProposeOutcome(allocator: std.mem.Allocator, text: []const u8) !ProposeOutcome {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    errdefer parsed.deinit();

    const root = parsed.value.object;
    const composed = root.get("composed").?.object;
    const patch = try allocator.dupe(u8, composed.get("patch").?.string);
    errdefer allocator.free(patch);

    const proposals = root.get("proposals").?.array;
    var first_hash: ?[]u8 = null;
    if (proposals.items.len > 0) {
        first_hash = try allocator.dupe(u8, proposals.items[0].object.get("expected_hash").?.string);
    }

    return .{
        .total = root.get("total").?.integer,
        .applied = composed.get("applied").?.array.items.len,
        .conflicts = composed.get("conflicts").?.array.items.len,
        .patch = patch,
        .first_hash = first_hash,
        .proposals_json = parsed,
    };
}

test "compose, classify, apply, and invalidate end to end" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    defer {
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db") catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db-wal") catch {};
        std.Io.Dir.cwd().deleteFile(io, "tests/.zero-noise/zero-noise.db-shm") catch {};
        std.Io.Dir.cwd().deleteDir(io, "tests/.zero-noise") catch {};
    }

    const e2e_path = "tests/test_e2e_apply.ts";
    const overlap_path = "tests/test_e2e_overlap.ts";
    const sf = try std.Io.Dir.cwd().createFile(io, e2e_path, .{});
    try sf.writeStreamingAll(io, E2E_TS_FIXTURE);
    sf.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, e2e_path) catch {};

    const of = try std.Io.Dir.cwd().createFile(io, overlap_path, .{});
    try of.writeStreamingAll(io, E2E_OVERLAP_FIXTURE);
    of.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, overlap_path) catch {};

    // 1. propose_fixes(compose=true) composes both guard proposals.
    const propose_args = try e2eProposeArgs(allocator, e2e_path, true, true);
    defer allocator.free(propose_args);
    const propose_out = try e2eToolCall(allocator, 30, "propose_fixes", propose_args);
    defer propose_out.deinit(allocator);
    try std.testing.expect(!propose_out.is_error);

    var step1 = try e2eProposeOutcome(allocator, propose_out.text);
    defer step1.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 2), step1.total);
    try std.testing.expectEqual(@as(usize, 2), step1.applied);
    try std.testing.expectEqual(@as(usize, 0), step1.conflicts);
    const patch_text = step1.patch;
    const old_hash = step1.first_hash.?;

    // 2. Applying a guard patch without a test command aborts and leaves the file untouched.
    const no_test_args = try e2eApplyArgs(allocator, e2e_path, patch_text, "guard", null, null);
    defer allocator.free(no_test_args);
    const no_test_out = try e2eToolCall(allocator, 31, "safe_refactor", no_test_args);
    defer no_test_out.deinit(allocator);
    try std.testing.expect(no_test_out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, no_test_out.text, "test_cmd required for guard/predicate patches") != null);

    const untouched = try runner.readFileAlloc(allocator, e2e_path);
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings(E2E_TS_FIXTURE, untouched);

    // 3. With a test command the patch is classified, applied, and verified.
    const with_test_args = try e2eApplyArgs(allocator, e2e_path, patch_text, "guard", "zig version", null);
    defer allocator.free(with_test_args);
    const with_test_out = try e2eToolCall(allocator, 32, "safe_refactor", with_test_args);
    defer with_test_out.deinit(allocator);
    try std.testing.expect(!with_test_out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, with_test_out.text, "\"status\":\"verified\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_test_out.text, "\"classification\":\"verified\"") != null);

    const applied_content = try runner.readFileAlloc(allocator, e2e_path);
    defer allocator.free(applied_content);
    try std.testing.expectEqualStrings(E2E_TS_EXPECTED, applied_content);

    // 4. Re-planning yields proposals locked to the new file state.
    const replan_args = try e2eProposeArgs(allocator, e2e_path, true, true);
    defer allocator.free(replan_args);
    const replan_out = try e2eToolCall(allocator, 33, "propose_fixes", replan_args);
    defer replan_out.deinit(allocator);
    try std.testing.expect(!replan_out.is_error);

    var step4 = try e2eProposeOutcome(allocator, replan_out.text);
    defer step4.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), step4.total);
    for (step4.proposals_json.value.object.get("proposals").?.array.items) |item| {
        const hash = item.object.get("expected_hash").?.string;
        try std.testing.expect(!std.mem.eql(u8, hash, old_hash));
    }

    // 5. The pre-apply hash is stale: applying with it aborts the state lock.
    const stale_args = try e2eApplyArgs(allocator, e2e_path, patch_text, "guard", "zig version", old_hash);
    defer allocator.free(stale_args);
    const stale_out = try e2eToolCall(allocator, 34, "safe_refactor", stale_args);
    defer stale_out.deinit(allocator);
    try std.testing.expect(stale_out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, stale_out.text, "state lock failed") != null);

    // 6. Overlapping guard/constant proposals compose a subset and report the conflict.
    const overlap_args = try e2eProposeArgs(allocator, overlap_path, true, false);
    defer allocator.free(overlap_args);
    const overlap_out = try e2eToolCall(allocator, 35, "propose_fixes", overlap_args);
    defer overlap_out.deinit(allocator);
    try std.testing.expect(!overlap_out.is_error);

    var overlap = try e2eProposeOutcome(allocator, overlap_out.text);
    defer overlap.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 2), overlap.total);
    try std.testing.expectEqual(@as(usize, 1), overlap.applied);
    try std.testing.expectEqual(@as(usize, 1), overlap.conflicts);

    // 7. Identical input yields byte-identical JSON.
    const deterministic_args = try e2eProposeArgs(allocator, overlap_path, true, true);
    defer allocator.free(deterministic_args);
    const first_out = try e2eToolCall(allocator, 36, "propose_fixes", deterministic_args);
    defer first_out.deinit(allocator);
    const second_out = try e2eToolCall(allocator, 37, "propose_fixes", deterministic_args);
    defer second_out.deinit(allocator);
    try std.testing.expectEqualStrings(first_out.text, second_out.text);
}
