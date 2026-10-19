# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Applicable-Fix Engine**: Byte-range edit engine with overlap detection — deterministic proposals rendered as unified diffs.
- **Proposal Model**: Every proposal carries a SHA-256 `expected_hash` state lock; non-overlapping proposals compose greedily into one applicable candidate with explicit conflict reporting.
- **AST Rewrite Passes**: Guard extraction (early return), repeated-literal constants, compound-boolean predicates, and long-closure extraction, with a per-language capability matrix — guards and constants on Go, Rust, Zig, TypeScript/TSX, Python, and C#; predicates and closures on TypeScript/TSX and Python (advisory elsewhere).
- **`propose_fixes` MCP Tool**: Paged fix proposals with optional per-proposal patches (`include_patches`) and composed candidates (`compose`).
- **`plan` CLI Command**: `zero-noise plan <path>` with `--include-patches`, `--compose`/`--out` composition, and `--kinds`, `--page`, `--page-size`, `--root` filters.
- **Classification-Verified Apply Contract**: Applications must declare an explicit `patch_kind` (`guard|predicate|constant|closure|boolean|manual`); the engine verifies it against its own proposals and aborts on mismatch. Guard and predicate patches are rejected without `test_cmd`. Dry-run remains the default (`fix=true` / `--fix` opt-in).

## [0.1.0] - 2026-10-17

### Added

- **Native Engine**: Reconstructed core analysis and mutation pipeline into a native Zig static binary with zero external runtime dependencies.
- **Embedded Parsers**: Integrated Tree-sitter C ABI core with embedded grammar parsers for Go, Rust, Python, TypeScript/TSX, C#, and Zig.
- **State Storage**: In-memory task ledger and symbol index with SHA-256 file state locking (SQLite was removed by a clean break; file-based persistence is tracked for a future release).
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
