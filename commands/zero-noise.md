---
description: "Refactor code for zero structural noise (DRY, early return, semantic predicates)"
argument-hint: "[target-path]"
allowed-tools: ["run_command", "view_file", "replace_file_content", "write_to_file"]
---

# /zero-noise Refactor Command

Audits and refactors target files or directories to eliminate structural debt, deep nesting, inline closures, and raw boolean expressions.

**Target Path (optional):** "$ARGUMENTS"

## Tool Suite Overview

The refactor suite provides 7 tools available as native MCP tools or native CLI commands:

| Tool | CLI Command | Description |
|------|-------------|-------------|
| `inspect_evidence` | `zero-noise audit --format=compact` | Unified Evidence Contract crossing noise, complexity, and blast radius with state lock |
| `audit_noise` | `zero-noise audit` | Structural noise linter (nesting > 2, closures > 80 chars, raw booleans, commented code) |
| `refactor_helper` | `zero-noise refactor --dry-run` | DRY duplicate literals and algebraic boolean simplifications |
| `complexity` | `zero-noise complexity` | SonarSource Cognitive Complexity per function (threshold default: 15) |
| `blast_radius` | `zero-noise blast` | Symbol usages, definitions, and cross-module blast radius |
| `safe_refactor` | `zero-noise refactor` | Test-bracketed refactoring with state-lock hash verification and atomic rollback |
| `evaluate_rules` | `zero-noise audit` | Declarative anti-pattern rules from `.zero-noise-rules.json` |

## When NOT to Use

Skip refactoring on:
- Generated or vendored code (`*.pb.go`, `*.g.dart`, `dist/`, `vendor/`, `node_modules/`).
- State machines, lexers, or protocol parsers with deliberate nested transition tables.
- Performance-critical hot paths without an available benchmark gate.
- Public/exported APIs before validating callers via `blast_radius`.

## Execution Workflow

1. **Resolve Target Scope & Anti-Use Gate:**
   - If `$ARGUMENTS` is provided, audit that file or directory; otherwise inspect `git status --porcelain`.
   - Abort immediately if the target falls under **When NOT to Use**.

2. **Step 1: Evidence, Structural & Complexity Audit:**
   - Generate the unified Evidence Pack (`inspect_evidence` via MCP or `zero-noise audit <target-path> --format=compact`) and capture `state_lock_sha256` (`expected_hash`).
   - Run structural noise and cognitive complexity checks:
     ```bash
     zero-noise audit <target-path>
     zero-noise complexity <target-path> --threshold=15
     ```
   - If the target is a hot path and the repo has benchmarks, record baseline benchmark metrics before editing.

3. **Step 2: Blast Radius & Candidate Analysis:**
   - If touching public/shared symbols, evaluate caller impact first:
     ```bash
     zero-noise blast <symbol> --root=.
     ```
   - Preview DRY literal extractions and algebraic boolean candidates:
     ```bash
     zero-noise refactor <target-path> --dry-run
     ```

4. **Step 3: Scoped Proposal (One Concern per Pass — Never Blind-Fix):**
   - Cap each pass/diff/commit to **one structural concern** (guards, predicates/closures, boolean algebra, or DRY constants).
   - Flatten nested blocks using **Early Return** guards (max depth `<= 2`), preserving short-circuit nil/bounds guard order.
   - Extract inline closures (`>2` lines or `>80` chars) to **pure named functions** passed by reference.
   - Replace compound conditions (`a && (b || c)`) with **domain predicates** preserving the repository's **ubiquitous language** (never synonymize existing repo terms; propose and wait for approval if domain naming is ambiguous).
   - Verify operands are pure and panic-free before applying **De Morgan**; if side-effects or panic guards exist, isolate them first or skip.

5. **Step 4: State-Locked Safe Delivery & Verification:**
   - Execute the proposed pass with state-lock verification, test bracketing, and automatic atomic rollback:
     ```bash
     zero-noise refactor <target-path> --expected-hash="<sha256>" --test-cmd="<project-test-cmd>" --fix
     ```
   - Re-run `zero-noise audit <target-path>` (noise score must reach `0`, exit code `0`) and re-run benchmarks on hot paths to confirm zero cost regression.
