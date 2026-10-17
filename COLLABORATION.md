# Collaboration Guide

Guidelines for contributing to `zero-noise`.

## Quickstart

```bash
# Clone the repository
git clone https://github.com/xdvi/zero-noise.git
cd zero-noise

# Build binary
zig build

# Run full test suite (Zig native tests)
zig build test

# Run manifest consistency check
python3 scripts/sync_manifests.py --check
```

## Contribution Workflow

1. **Branch Naming**: Use scoped branch names (`feat/symbol-indexer`, `fix/windows-rename`, `perf/parser-pool`).
2. **Atomic Commits**: Group related changes into single reviewable commits.
3. **Run Quality Gates**: Ensure all tests and static analysis pass before pushing.
4. **Pull Requests**: Provide a concise summary of the change, affected modules, and verification proof.

## Commit Standards

Commits must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

| Type | Purpose | Example |
|------|---------|---------|
| `feat` | New capability or tool | `feat(analysis): support cognitive complexity for c#` |
| `fix` | Bug fix in engine, parser, or runner | `fix(runner): ensure cross-platform atomic file rename` |
| `perf` | Performance improvement or binary size reduction | `perf(build): enable link-time optimization and symbol stripping` |
| `refactor` | Structural code change without behavior changes | `refactor(mcp): streamline tool dispatch loop` |
| `test` | Adding or updating unit/integration tests | `test(storage): add multi-threaded wal ledger tests` |
| `docs` | Documentation updates | `docs: update collaboration workflow and cli guides` |
| `ci` | CI/CD pipeline or release workflow updates | `ci: update action runners to latest stable versions` |

Do not add attribution trailers or co-author tags to commit messages.

## Architectural Invariants

Contributors must maintain the following architectural constraints:

- **Zero External Runtime Dependencies**: The compiled binary must be fully standalone. Dynamic linking of third-party libraries (outside libc) is prohibited.
- **Embedded C ABI**: Tree-sitter parsers and SQLite must remain embedded C sources compiled directly by `zig build`.
- **State-Lock Safety**: All refactoring mutations must verify disk state via SHA-256 before modifying files.
- **Leak-Free Memory**: All heap allocations must pass through managed Zig allocators. Tests must run without memory leaks.
- **Cross-Platform Parity**: File operations, child processes, and paths must behave identically across Linux, macOS, and Windows.

## Quality Checklist

Before submitting a pull request, verify:

- [ ] `zig build test` passes with 0 failures and 0 memory leaks.
- [ ] Cross-platform compatibility is preserved (no POSIX-only APIs without cross-platform shims).
- [ ] Any new CLI or MCP parameters are reflected in `src/mcp/protocol.zig` and synchronized via `scripts/sync_manifests.py`.
- [ ] Code follows zero-noise structural rules: nesting depth <= 2, early returns for guards, and semantic predicate naming.
