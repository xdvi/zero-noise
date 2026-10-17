# zero-noise plugin

**Stack**: Go · Rust · TypeScript · Python · C#  
**Trigger**: refactor, clean code, DRY, early return, zero-noise, reduce complexity

## Skills

| Skill | Path | Trigger |
|-------|------|---------|
| zero-noise-refactor | [skills/zero-noise-refactor/](skills/zero-noise-refactor/) | refactoring, clean code, legacy cleanup, cyclomatic complexity, technical debt |

## Commands

| Command | Path | Description |
|---------|------|-------------|
| /zero-noise | [commands/zero-noise.md](commands/zero-noise.md) | Slash command for 5-step structural noise audit and refactor |

## Agents

| Agent | Path | Description |
|-------|------|-------------|
| zero-noise-refactor | [agents/zero-noise-refactor.md](agents/zero-noise-refactor.md) | Structural noise auditor and refactor executor |

## MCP Server

Exposes 7 native typed tools via standard JSON-RPC 2.0 stdio (`zero-noise mcp`):

| Tool | Parameters | Description |
|------|------------|-------------|
| `inspect_evidence` | `path` (req), `root`, `page`, `page_size` | Cross-references noise, complexity, and blast radius into a prioritized, state-locked Evidence Contract pack |
| `audit_noise` | `path` (req), `format`, `config` | Static structural linter (nesting > 2, closures > 80 chars, raw booleans, commented code) |
| `refactor_helper` | `filepath` (req) | Detects DRY repeated literals and algebraic boolean simplifications |
| `complexity` | `path` (req), `threshold`, `format` | Calculates SonarSource Cognitive Complexity per function (default threshold: 15) |
| `blast_radius` | `symbol` (req), `root`, `format` | Analyzes symbol usages, definitions, and cross-file coupling risk |
| `safe_refactor` | `filepath` (req), `expected_hash`, `max_blast_risk`, `test_cmd`, `fix`, `format` | Test-bracketed refactoring runner with state-lock hash verification and atomic rollback |
| `evaluate_rules` | `path` (req), `rules`, `format` | Evaluates declarative AST and regex anti-pattern rules from `.zero-noise-rules.json` |


## Source of Truth

Metadata is centrally managed in [manifest.json](manifest.json) and synchronized to all CLI descriptors via:
```bash
python3 scripts/sync_manifests.py
```
