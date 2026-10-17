const std = @import("std");

pub const treesitter = struct {
    pub const bindings = @import("treesitter/bindings.zig");
    pub const grammars = @import("treesitter/grammars.zig");
};

pub const storage = struct {
    pub const db = @import("storage/db.zig");
    pub const ledger = @import("storage/ledger.zig");
};

pub const analysis = struct {
    pub const noise = @import("analysis/noise.zig");
    pub const complexity = @import("analysis/complexity.zig");
    pub const blast = @import("analysis/blast.zig");
};

pub const mutation = struct {
    pub const runner = @import("mutation/runner.zig");
    pub const rewriter = @import("mutation/rewriter.zig");
};

pub const mcp = struct {
    pub const protocol = @import("mcp/protocol.zig");
    pub const compact = @import("mcp/compact.zig");
    pub const server = @import("mcp/server.zig");
    pub const app = @import("mcp/app.zig");
};

pub const cli = struct {
    pub const audit = @import("cli/audit.zig");
    pub const complexity = @import("cli/complexity.zig");
    pub const blast = @import("cli/blast.zig");
    pub const refactor = @import("cli/refactor.zig");
};

pub fn getSqliteVersion() [*:0]const u8 {
    return storage.db.sqlite.sqlite3_libversion();
}

test {
    _ = @import("treesitter/bindings.zig");
    _ = @import("treesitter/grammars.zig");
    _ = @import("storage/db.zig");
    _ = @import("storage/ledger.zig");
    _ = @import("analysis/noise.zig");
    _ = @import("analysis/complexity.zig");
    _ = @import("analysis/blast.zig");
    _ = @import("mutation/rewriter.zig");
    _ = @import("mutation/runner.zig");
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/compact.zig");
    _ = @import("mcp/server.zig");
    _ = @import("cli/audit.zig");
    _ = @import("cli/complexity.zig");
    _ = @import("cli/blast.zig");
    _ = @import("cli/refactor.zig");
}
