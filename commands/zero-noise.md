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

## Execution Workflow

1. **Resolve Target Scope:**
   - If `$ARGUMENTS` is provided, audit that file or directory.
   - If empty, inspect `git status --porcelain` to identify modified files in the working directory.

2. **Step 1: Structural, Complexity & Rules Audit:**
   - Run structural noise linter:
     ```bash
     zero-noise audit <target-path>
     ```
     Record issues: nesting depth > 2, unextracted inline closures, redundant ternaries, raw complex conditionals.
   - Run cognitive complexity analyzer:
     ```bash
     zero-noise complexity <target-path> --threshold 15
     ```

3. **Step 2: Impact & Blast Radius Analysis:**
   - If renaming or extracting public/shared symbols, evaluate blast radius:
     ```bash
     zero-noise blast <symbol> --root .
     ```

4. **Step 3: Zero-Noise Refactoring:**
   - Flatten nested blocks using **Early Return** guards (max depth <= 2).
   - Extract raw inline closures to **pure named functions** passed by reference.
   - Replace complex conditions (`a && (b || c)`) with **semantic domain predicates** (`isAuthorizedSession()`).
   - Eliminate duplicated literals into domain constants.
   - Preserve exact external behavior and API contracts.

5. **Step 4: Safe Verification & Rollback Protection:**
   - Execute test-bracketed verification with automatic atomic rollback on failure:
     ```bash
     zero-noise refactor <target-path> --test-cmd "<project-test-cmd>" --fix
     ```
   - Re-run `zero-noise audit <target-path>`. The score must reach 0 (exit code 0).
