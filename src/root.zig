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
    pub const edits = @import("mutation/edits.zig");
    pub const proposal = @import("mutation/proposal.zig");
    pub const propose = @import("mutation/propose.zig");
    pub const rewrite_closures = @import("mutation/rewrite_closures.zig");
    pub const rewrite_constants = @import("mutation/rewrite_constants.zig");
    pub const rewrite_guards = @import("mutation/rewrite_guards.zig");
    pub const rewrite_predicates = @import("mutation/rewrite_predicates.zig");
    pub const runner = @import("mutation/runner.zig");
    pub const io = @import("mutation/io.zig");
    pub const patch = @import("mutation/patch.zig");
    pub const syntax = @import("mutation/syntax.zig");
    pub const test_runner = @import("mutation/test_runner.zig");
    pub const rewriter = @import("mutation/rewriter.zig");
};

pub const mcp = struct {
    pub const protocol = @import("mcp/protocol.zig");
    pub const compact = @import("mcp/compact.zig");
    pub const server = @import("mcp/server.zig");
    pub const app = @import("mcp/app.zig");
    pub const common = @import("mcp/common.zig");
    pub const format = @import("mcp/format.zig");
    pub const risk = @import("mcp/risk.zig");
    pub const deps = @import("mcp/deps.zig");
    pub const tools = struct {
        pub const audit_noise = @import("mcp/tools/audit_noise.zig");
        pub const refactor_helper = @import("mcp/tools/refactor_helper.zig");
        pub const blast_radius = @import("mcp/tools/blast_radius.zig");
        pub const inspect_evidence = @import("mcp/tools/inspect_evidence.zig");
        pub const safe_refactor = @import("mcp/tools/safe_refactor.zig");
        pub const propose_fixes = @import("mcp/tools/propose_fixes.zig");
        pub const complexity = @import("mcp/tools/complexity.zig");
        pub const evaluate_rules = @import("mcp/tools/evaluate_rules.zig");
    };
};

pub const cli = struct {
    pub const audit = @import("cli/audit.zig");
    pub const complexity = @import("cli/complexity.zig");
    pub const blast = @import("cli/blast.zig");
    pub const refactor = @import("cli/refactor.zig");
    pub const plan = @import("cli/plan.zig");
};

test {
    _ = @import("treesitter/bindings.zig");
    _ = @import("treesitter/grammars.zig");
    _ = @import("storage/db.zig");
    _ = @import("storage/ledger.zig");
    _ = @import("analysis/noise.zig");
    _ = @import("analysis/complexity.zig");
    _ = @import("analysis/blast.zig");
    _ = @import("mutation/edits.zig");
    _ = @import("mutation/proposal.zig");
    _ = @import("mutation/propose.zig");
    _ = @import("mutation/rewrite_closures.zig");
    _ = @import("mutation/rewrite_constants.zig");
    _ = @import("mutation/rewrite_guards.zig");
    _ = @import("mutation/rewrite_predicates.zig");
    _ = @import("mutation/rewriter.zig");
    _ = @import("mutation/runner.zig");
    _ = @import("mutation/io.zig");
    _ = @import("mutation/patch.zig");
    _ = @import("mutation/syntax.zig");
    _ = @import("mutation/test_runner.zig");
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/compact.zig");
    _ = @import("mcp/common.zig");
    _ = @import("mcp/format.zig");
    _ = @import("mcp/risk.zig");
    _ = @import("mcp/deps.zig");
    _ = @import("mcp/tools/audit_noise.zig");
    _ = @import("mcp/tools/refactor_helper.zig");
    _ = @import("mcp/tools/blast_radius.zig");
    _ = @import("mcp/tools/inspect_evidence.zig");
    _ = @import("mcp/tools/safe_refactor.zig");
    _ = @import("mcp/tools/propose_fixes.zig");
    _ = @import("mcp/tools/complexity.zig");
    _ = @import("mcp/tools/evaluate_rules.zig");
    _ = @import("mcp/server.zig");
    _ = @import("mcp/app.zig");
    _ = @import("cli/audit.zig");
    _ = @import("cli/complexity.zig");
    _ = @import("cli/blast.zig");
    _ = @import("cli/refactor.zig");
    _ = @import("cli/plan.zig");
}
