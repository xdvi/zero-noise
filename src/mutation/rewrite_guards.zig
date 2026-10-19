const std = @import("std");
const bindings = @import("../treesitter/bindings.zig");
const grammars = @import("../treesitter/grammars.zig");
const proposal = @import("proposal.zig");

pub fn supportedLanguages() []const grammars.Language {
    return &.{};
}

pub fn collect(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: grammars.Language,
    root: bindings.TSNode,
) anyerror![]proposal.Proposal {
    _ = allocator;
    _ = source;
    _ = lang;
    _ = root;
    return &.{};
}
