const std = @import("std");
const bindings = @import("bindings.zig");

pub const Language = enum {
    go,
    rust,
    python,
    typescript,
    tsx,
    c_sharp,
    unknown,

    pub fn getTsLanguage(self: Language) ?*const bindings.TSLanguage {
        return switch (self) {
            .go => bindings.tree_sitter_go(),
            .rust => bindings.tree_sitter_rust(),
            .python => bindings.tree_sitter_python(),
            .typescript => bindings.tree_sitter_typescript(),
            .tsx => bindings.tree_sitter_tsx(),
            .c_sharp => bindings.tree_sitter_c_sharp(),
            .unknown => null,
        };
    }

    pub fn fromExtension(ext: []const u8) Language {
        if (std.mem.eql(u8, ext, ".go")) return .go;
        if (std.mem.eql(u8, ext, ".rs")) return .rust;
        if (std.mem.eql(u8, ext, ".py")) return .python;
        if (std.mem.eql(u8, ext, ".ts")) return .typescript;
        if (std.mem.eql(u8, ext, ".tsx") or std.mem.eql(u8, ext, ".jsx")) return .tsx;
        if (std.mem.eql(u8, ext, ".js")) return .typescript;
        if (std.mem.eql(u8, ext, ".cs")) return .c_sharp;
        return .unknown;
    }

    pub fn fromPath(path: []const u8) Language {
        const ext = std.fs.path.extension(path);
        return fromExtension(ext);
    }

    pub fn fromName(name: []const u8) Language {
        if (std.ascii.eqlIgnoreCase(name, "go")) return .go;
        if (std.ascii.eqlIgnoreCase(name, "rust") or std.ascii.eqlIgnoreCase(name, "rs")) return .rust;
        if (std.ascii.eqlIgnoreCase(name, "python") or std.ascii.eqlIgnoreCase(name, "py")) return .python;
        if (std.ascii.eqlIgnoreCase(name, "typescript") or std.ascii.eqlIgnoreCase(name, "ts")) return .typescript;
        if (std.ascii.eqlIgnoreCase(name, "tsx")) return .tsx;
        if (std.ascii.eqlIgnoreCase(name, "javascript") or std.ascii.eqlIgnoreCase(name, "js")) return .typescript;
        if (std.ascii.eqlIgnoreCase(name, "csharp") or std.ascii.eqlIgnoreCase(name, "cs") or std.ascii.eqlIgnoreCase(name, "c_sharp")) return .c_sharp;
        return .unknown;
    }
};
