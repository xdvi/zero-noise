const std = @import("std");
const zn = @import("zero-noise");

fn printUsage(io: std.Io, stdout: std.Io.File) !void {
    const usage =
        \\zero-noise: structural code quality & AST analysis engine
        \\
        \\Usage:
        \\  zero-noise <command> [arguments...] [options]
        \\
        \\Commands:
        \\  mcp                  Start Model Context Protocol (MCP) JSON-RPC 2.0 stdio server
        \\  audit [paths...]     Audit files for nesting, closures, and structural noise
        \\  complexity [paths..] Calculate SonarSource cognitive complexity per function
        \\  blast <symbol>       Analyze definition, references, and blast radius risk
        \\  refactor <file>      Execute transactional safe refactor with hash verification
        \\  version              Print zero-noise version
        \\  help                 Show this help message
        \\
        \\Options:
        \\  --format=<format>    Output format: text, json, sarif, or compact
        \\  --threshold=<num>    Complexity threshold (default: 15)
        \\  --root=<path>        Project root directory (default: .)
        \\  --fix                Apply automatic simplifications
        \\  --force              Bypass blast radius check
        \\  --test-cmd=<cmd>     Test command for refactor verification
        \\  -h, --help           Show help
        \\  -v, --version        Show version
        \\
    ;
    try stdout.writeStreamingAll(io, usage);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len <= 1) {
        try printUsage(io, stdout);
        return 0;
    }

    const command = args[1];
    const sub_args = args[2..];

    if (std.mem.eql(u8, command, "mcp")) {
        try zn.mcp.server.run(allocator);
        return 0;
    } else if (std.mem.eql(u8, command, "audit")) {
        return try zn.cli.audit.run(allocator, sub_args, io, stdout);
    } else if (std.mem.eql(u8, command, "complexity")) {
        return try zn.cli.complexity.run(allocator, sub_args, io, stdout);
    } else if (std.mem.eql(u8, command, "blast")) {
        return try zn.cli.blast.run(allocator, sub_args, io, stdout, stderr);
    } else if (std.mem.eql(u8, command, "refactor")) {
        return try zn.cli.refactor.run(allocator, sub_args, io, stdout, stderr);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        const ver_str = try std.fmt.allocPrint(allocator, "zero-noise {s} (SQLite {s})\n", .{
            zn.mcp.protocol.SERVER_VERSION,
            zn.getSqliteVersion(),
        });
        defer allocator.free(ver_str);
        try stdout.writeStreamingAll(io, ver_str);
        return 0;
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(io, stdout);
        return 0;
    } else {
        const err_msg = try std.fmt.allocPrint(allocator, "zero-noise: unknown command '{s}'. Run 'zero-noise --help' for usage.\n", .{command});
        defer allocator.free(err_msg);
        try stderr.writeStreamingAll(io, err_msg);
        return 1;
    }
}
