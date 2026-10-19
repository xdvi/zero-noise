# zero-noise plugin

**Stack**: Go · Rust · TypeScript · Python · C# · Zig  
**Trigger**: refactor, clean code, DRY, early return, zero-noise, reduce complexity

## Skills

| Skill | Path | Trigger |
|-------|------|---------|
| zero-noise-refactor | [skills/zero-noise-refactor/](skills/zero-noise-refactor/) | refactoring, clean code, legacy cleanup, cyclomatic complexity, technical debt |

## Commands

| Command | Path | Description |
|---------|------|-------------|
| /zero-noise | [commands/zero-noise.md](commands/zero-noise.md) | Slash command for 5-step structural noise audit and refactor |

Native CLI (`zero-noise <command>`):

| Command | Description |
|---------|-------------|
| `zero-noise refactor <file>` | Dry-run by default; `--fix` applies with `--expected-hash` and `--test-cmd`; patch applications require `--patch-kind`; guard/predicate patches require `--test-cmd` |
| `zero-noise plan <path>` | Lists fix proposals with `expected_hash` state locks; `--include-patches`, `--compose`, `--out=<file>`, `--kinds`, `--page`, `--page-size`, `--format` |

## Agents

| Agent | Path | Description |
|-------|------|-------------|
| zero-noise-refactor | [agents/zero-noise-refactor.md](agents/zero-noise-refactor.md) | Structural noise auditor and refactor executor |

## MCP Server

Exposes 8 native typed tools via standard JSON-RPC 2.0 stdio (`zero-noise mcp`):

| Tool | Parameters | Description |
|------|------------|-------------|
| `inspect_evidence` | `path` (req), `root`, `page`, `page_size` | Cross-references noise, complexity, and blast radius into a prioritized, state-locked Evidence Contract pack |
| `audit_noise` | `path` (req), `format`, `config` | Static structural linter (nesting > 2, closures > 80 chars, raw booleans, commented code) |
| `refactor_helper` | `filepath` (req) | Detects DRY repeated literals and algebraic boolean simplifications |
| `complexity` | `path` (req), `threshold`, `format` | Calculates SonarSource Cognitive Complexity per function (default threshold: 15) |
| `blast_radius` | `symbol` (req), `root`, `format` | Analyzes symbol usages, definitions, and cross-file coupling risk |
| `safe_refactor` | `filepath` (req), `expected_hash`, `max_blast_risk`, `test_cmd`, `fix`, `format`, `candidate_content`, `patch_content`, `patch_file`, `patch_kind`, `force`, `root` | Test-bracketed refactoring runner with state-lock hash verification, classification-verified `patch_kind`, and atomic rollback |
| `propose_fixes` | `path` (req), `kinds`, `include_patches`, `compose`, `page`, `page_size`, `format`, `root` | Lists machine-applicable fix proposals (guard, predicate, constant, closure) with state-lock hashes and optional composed patches |
| `evaluate_rules` | `path` (req), `rules`, `format` | Evaluates declarative AST and regex anti-pattern rules from `.zero-noise-rules.json` |


## Source of Truth

Metadata is centrally managed in [manifest.json](manifest.json) and synchronized to all CLI descriptors via:
```bash
python3 scripts/sync_manifests.py
```
