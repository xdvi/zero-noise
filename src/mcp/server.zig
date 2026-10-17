const std = @import("std");
const protocol = @import("protocol.zig");
const app = @import("app.zig");
const deps_mod = @import("deps.zig");

pub fn handleJsonRpcLineWithDeps(
    allocator: std.mem.Allocator,
    line: []const u8,
    deps_ptr: *const deps_mod.Deps,
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

        const tool_result = app.executeToolCallWithDeps(allocator, tool_name, arguments, deps_ptr) catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "Tool execution error: {s}", .{@errorName(err)});
            defer allocator.free(err_msg);
            const call_res = try protocol.buildToolCallResultJson(allocator, err_msg, true);
            defer allocator.free(call_res);
            return try protocol.buildSuccessResponseJson(allocator, req_id, call_res);
        };
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

    const buffer_size: usize = 1024 * 1024;
    const in_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(in_buf);
    var reader = stdin.readerStreaming(io, in_buf);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;

        var req_arena = std.heap.ArenaAllocator.init(allocator);
        defer req_arena.deinit();
        const req_alloc = req_arena.allocator();

        const default_deps = deps_mod.defaultDeps();
        const maybe_resp = handleJsonRpcLineWithDeps(req_alloc, line, &default_deps) catch |err| {
            const err_resp = protocol.buildErrorResponseJson(req_alloc, .null_id, protocol.ErrorCodes.InternalError, @errorName(err)) catch null;
            if (err_resp) |resp| {
                stdout.writeStreamingAll(io, resp) catch {};
                stdout.writeStreamingAll(io, "\n") catch {};
            }
            continue;
        };
        if (maybe_resp) |resp| {
            try stdout.writeStreamingAll(io, resp);
            try stdout.writeStreamingAll(io, "\n");
        }
    }
}

pub fn handleJsonRpcLine(
    allocator: std.mem.Allocator,
    line: []const u8,
) !?[]const u8 {
    const default = deps_mod.defaultDeps();
    return handleJsonRpcLineWithDeps(allocator, line, &default);
}
