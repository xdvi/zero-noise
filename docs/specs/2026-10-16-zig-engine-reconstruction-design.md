# Design Spec: Zero-Noise Native Zig Engine Reconstruction

**Status**: Validated Design  
**Date**: 2026-10-16  
**Scope**: Full architectural port from Python scripts to a single static native Zig binary (`zero-noise`) embedding Tree-sitter C ABI and SQLite WAL state storage.

> **Storage superseded:** the SQLite WAL storage design in this document was
> deliberately removed by the clean break (`f462d18`); persistence is file-based —
> see `docs/superpowers/specs/2026-10-18-rea-parity-design.md` (P2.5).

---

## 1. Executive Summary & Goals

`zero-noise` automates structural code quality, flattening nested control flow (Early Return), naming domain predicates, enforcing DRY literals, and eliminating inline closures across Go, Rust, TypeScript, Python, and C#.

Currently, `zero-noise` relies on Python scripts with regex and partial AST approximations. This spec details the architecture to reconstruct `zero-noise` into an industrial-grade, single-binary Zig framework that:
1. **Zero Runtime Dependencies**: No Python, Node.js, GCC, or external runtimes required by end users.
2. **Deterministic Speed**: Sub-millisecond startup (<1 ms), parsing 50k+ lines in <20 ms via Zig multi-threaded `ArenaAllocator` and Tree-sitter C ABI.
3. **100% Compiler-Accurate AST**: Direct C linkage of Tree-sitter parsers for Go, Rust, TypeScript, Python, and C#.
4. **State-Locked Concurrency & Transaction Ledger**: Embedded SQLite in WAL mode (`.zero-noise/state.db`) providing multi-agent ACID concurrency, hash locking, and atomic rollback without running background daemons.
5. **Universal Cross-Platform Distribution**: Pre-compiled static binaries for Linux (x86_64, aarch64 musl), macOS (ARM64 Apple Silicon, x86_64 Intel), and Windows (x86_64 exe).

---

## 2. System Architecture

```text
+-----------------------------------------------------------------------------------------+
|                                    zero-noise CLI / MCP                                 |
|                                                                                         |
|  [CLI Subcommands]              [MCP stdio Server (JSON-RPC 2.0)]                       |
|  audit | complexity | blast |   inspect_evidence | audit_noise | complexity | safe_refactor|
+-----------------------------------------------------------------------------------------+
                                             |
                                             v
+-----------------------------------------------------------------------------------------+
|                                    Analysis Core                                        |
|                                                                                         |
|  +--------------------+  +----------------------+  +---------------------------------+  |
|  |  Noise & Nesting   |  | Cognitive Complexity |  |         Blast Radius            |  |
|  | (Depth, Closures,  |  | (SonarSource Rules,  |  |   (Symbol Reference Indexer,    |  |
|  |  Redundant Logic)  |  |  Nesting Penalties)  |  |    Def vs Usage Classifier)     |  |
|  +--------------------+  +----------------------+  +---------------------------------+  |
+-----------------------------------------------------------------------------------------+
         |                                                           |
         v                                                           v
+------------------------------------+             +--------------------------------------+
|       Tree-sitter C Engine         |             |       Embedded Storage & Ledger      |
|  libtree-sitter (C API)            |             |  sqlite3.c (WAL Mode)                |
|  Grammars: Go, Rust, TS, Py, C#    |             |  .zero-noise/state.db                |
|  Per-file Arena Allocator (0-leak) |             |  (Files, Symbols, Refactor Ledger)   |
+------------------------------------+             +--------------------------------------+
                                             |
                                             v
+-----------------------------------------------------------------------------------------+
|                                Transactional Safe Runner                                |
|  Hash verification -> AST rewrite -> Syntax validate -> Test bracket -> Atomic swap/roll|
+-----------------------------------------------------------------------------------------+
```

---

## 3. Module Breakdown & Repository Layout

```text
zero-noise/
├── build.zig                 # Zig build configuration, C library compilation, targets
├── build.zig.zon             # Zig package dependencies (tree-sitter, grammars)
├── src/
│   ├── main.zig              # Entrypoint router (CLI vs MCP stdio mode)
│   ├── cli/
│   │   ├── audit.zig         # CLI audit noise implementation
│   │   ├── complexity.zig    # CLI complexity implementation
│   │   ├── blast.zig         # CLI blast radius implementation
│   │   └── refactor.zig      # CLI safe refactor / dry-run implementation
│   ├── mcp/
│   │   ├── server.zig        # JSON-RPC 2.0 stdio server loop
│   │   ├── protocol.zig      # Types (Initialize, ToolsList, ToolsCall, Response)
│   │   ├── handlers.zig      # Tool invocation dispatchers
│   │   └── compact.zig       # Ultra-compact token compression formatter
│   ├── treesitter/
│   │   ├── bindings.zig      # C FFI bindings (TSParser, TSTree, TSNode, TSCursor)
│   │   └── grammars.zig      # Grammar language initializers for Go, Rust, TS, Py, C#
│   ├── analysis/
│   │   ├── noise.zig         # Static structural rules (nesting > 2, closures, DRY)
│   │   ├── complexity.zig    # SonarSource Cognitive Complexity algorithm
│   │   └── blast.zig         # Symbol definitions, usages, and cross-file coupling
│   ├── storage/
│   │   ├── db.zig            # SQLite3 C wrapper, schema migrations, WAL pragmas
│   │   └── ledger.zig        # State lock and transactional refactor ledger
│   └── mutation/
│       ├── rewriter.zig      # Early return, domain predicates, De Morgan rewrites
│       └── runner.zig        # Test-bracketed execution with atomic file rollback
├── c/
│   ├── sqlite3.c             # SQLite 3 amalgamation source
│   ├── sqlite3.h
│   └── vendor/
│       └── tree-sitter/      # libtree-sitter C core source
├── .github/
│   └── workflows/
│       ├── ci.yml            # Automated testing across all platforms
│       └── release.yml       # Cross-compiled artifact generation & upload
└── install.sh                # Universal zero-dependency installer
```

---

## 4. Key Subsystem Specifications

### 4.1. Tree-sitter C Core & Multi-Language Parsing
- **Embedded C ABI**: Tree-sitter core (`libtree-sitter`) and language grammars are compiled directly into the binary via `build.zig` (`exe.addCSourceFile`).
- **Memory Management**: For each file, an `ArenaAllocator` wraps heap allocations. Upon AST traversal completion, `arena.deinit()` instantaneously frees all nodes in $O(1)$ without heap fragmentation.
- **Incremental Re-parsing**: In long-running MCP stdio sessions, file edits leverage `ts_tree_edit` for sub-millisecond updates instead of full-file re-lexing.

### 4.2. Embedded Storage & State Lock Ledger (`.zero-noise/state.db`)
- Embedded SQLite compiled with `SQLITE_THREADSAFE=1`, `SQLITE_ENABLE_WAL=1`.
- Initialized on demand in the project root under `.zero-noise/state.db`.
- **Schema**:
  ```sql
  CREATE TABLE IF NOT EXISTS file_cache (
      path TEXT PRIMARY KEY,
      mtime INTEGER NOT NULL,
      size INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      noise_count INTEGER NOT NULL,
      complexity INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS symbol_refs (
      symbol TEXT NOT NULL,
      file TEXT NOT NULL,
      line INTEGER NOT NULL,
      col INTEGER NOT NULL,
      is_definition INTEGER NOT NULL,
      PRIMARY KEY (symbol, file, line, col)
  );

  CREATE TABLE IF NOT EXISTS refactor_ledger (
      task_id TEXT PRIMARY KEY,
      file TEXT NOT NULL,
      expected_hash TEXT NOT NULL,
      initial_complexity INTEGER NOT NULL,
      initial_noise INTEGER NOT NULL,
      status TEXT NOT NULL, -- 'pending' | 'verified' | 'rolled_back'
      updated_at INTEGER NOT NULL
  );
  ```
- **Concurrency Guarantee**: Multiple concurrent CLI runs and parallel subagents read and write safely under WAL without lock contention or `SIGBUS` hazards.

### 4.3. Analysis & SonarSource Cognitive Complexity
- Exact implementation of SonarSource standard:
  - B1 increments: `if`, `ternary ? :`, `switch`/`match`, `for`, `while`, `catch`/`except`.
  - Nesting penalties: Structural blocks increment inner nesting level $+1$.
  - B2 increments: Sequences of logical operators (`&&`, `||`, `and`, `or`) increment on operator changes.
  - Optional chaining (`?.`) and nullable types (`int?`) are explicitly ignored by grammar-specific AST node inspection.

### 4.4. Transactional Safe Refactor & Atomic Rollback
1. **Pre-flight**:
   - Check `expected_hash` against `.zero-noise/state.db` and actual file SHA-256.
   - Evaluate `blast_radius` of all impacted symbols. Block changes if risk exceeds threshold unless `--force`.
2. **Execute Test Bracket**:
   - Write candidate content to a temporary sibling file (`.<filename>.tmp`).
   - Run syntax verification with native compiler (`ast.parse`, `tsc`, `gofmt`, `rustc`, `dotnet`).
   - Run user test suite (`--test-cmd`).
3. **Atomic Swap / Rollback**:
   - On success: `std.fs.Dir.rename` / `os.replace` atomically swaps `.tmp` into target path. Ledger marks task `verified`.
   - On failure: Temporary file unlinked, original untouched. Ledger marks task `rolled_back`.

---

## 5. Cross-Platform Compilation & Distribution

### 5.1. Build Targets (Zig Matrix)
All compiled from standard GitHub Actions runners using Zig's built-in cross-compiler:
- `x86_64-linux-musl` (Static Linux, 0 glibc dependencies)
- `aarch64-linux-musl` (Static Linux ARM64, Raspberry Pi / AWS Graviton)
- `aarch64-macos` (Apple Silicon macOS 11+)
- `x86_64-macos` (Intel macOS 10.15+)
- `x86_64-windows-gnu` (Windows 10/11 standalone `.exe`)

### 5.2. Installation Script (`install.sh`)
- Zero dependencies (pure POSIX shell + `curl`/`tar`/`unzip`).
- Probes architecture via `uname -s` and `uname -m`.
- Downloads matching pre-built release binary from GitHub Releases.
- Installs to `~/.local/bin/zero-noise` or custom destination.
- Updates editor/agent configs (Claude Code, OpenCode, Antigravity, Codex) automatically.

---

## 6. Migration & Backward Compatibility
- Existing MCP tool signatures (`inspect_evidence`, `audit_noise`, `complexity`, `blast_radius`, `safe_refactor`, `evaluate_rules`) remain 100% contract-compatible with existing agent integrations.
- Command-line flags (`--format=json`, `--format=sarif`, `--format=text`) maintain strict backward compatibility.
- New flag `--format=compact` introduced for ultra-dense, token-saving agent responses.
