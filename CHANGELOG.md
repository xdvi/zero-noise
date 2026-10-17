# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-17

### Added

- **Native Engine**: Reconstructed core analysis and mutation pipeline into a native Zig static binary with zero external runtime dependencies.
- **Embedded Parsers**: Integrated Tree-sitter C ABI core with embedded grammar parsers for Go, Rust, Python, TypeScript/TSX, and C#.
- **State Storage**: Embedded SQLite3 with WAL mode, task ledger, symbol indexing, and SHA-256 file state locking.
- **Model Context Protocol (MCP)**: JSON-RPC 2.0 stdio server (`zero-noise mcp`) exposing 7 typed tools:
  - `inspect_evidence`: Prioritized Evidence Contract crossing noise, cognitive complexity, and blast radius.
  - `audit_noise`: Static structural linter checking nesting depth > 2, closures > 80 chars, and raw booleans.
  - `complexity`: SonarSource Cognitive Complexity algorithm per function.
  - `blast_radius`: Cross-module symbol definition and reference caller analysis.
  - `safe_refactor`: Test-bracketed refactoring runner with state-lock verification and atomic rollback.
  - `refactor_helper`: DRY duplicate literal detection and algebraic boolean simplifications.
  - `evaluate_rules`: Declarative AST and regex rule validation.
- **CLI Commands**: Standalone subcommands for `audit`, `complexity`, `blast`, `refactor`, `version`, and `mcp`.
- **Cross-Platform Distribution**: Automated CI and release matrix producing stripped static binaries for `x86_64-linux-musl`, `aarch64-linux-musl`, `aarch64-macos`, `x86_64-macos`, and `x86_64-windows-gnu`.
- **Zero-Dependency Installer**: POSIX shell script (`install.sh`) supporting automated binary downloads, architecture detection, local builds, and editor plugin linking.
