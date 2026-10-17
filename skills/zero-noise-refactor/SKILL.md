---
name: zero-noise-refactor
description: "Trigger: refactor code, clean code, DRY, early return, zero-noise, complexity. Refactor code for zero structural noise, flattening nested logic, naming domain predicates, and simplifying boolean expressions across Go, Rust, TS, Python, and C#."
license: MIT
metadata:
  author: David
  version: "0.1.0"
---

## Activation Contract

Use this skill when:
- Encountering deep nesting (>2 levels), lengthy inline closures, or redundant temporary variables.
- Detecting DRY violations (duplicated code or string literals) or business logic scattered across UI/handlers.
- Refactoring legacy code into clean, agnostic, maintainable implementations without altering external behavior.
- Cognitive complexity exceeds threshold or cross-module coupling requires blast radius assessment.

## Hard Rules

- **Zero Behavior Change**: Preserve exact external behavior, signatures, and API contracts.
- **Inlining Ban**: Never keep anonymous closures >2 lines or >80 characters in argument position. Extract pure named functions passed by reference.
- **Absolute Early Return**: Invert conditions and return early. Maximum nesting depth is 2 levels.
- **Explicit Domain Predicates**: Replace compound boolean conditions (`a && (b || c)`) with domain-named functions (e.g. `isEligibleForExpressCheckout(cart)`).
- **Single Source of Truth (DRY)**: Extract repeated string literals (frequency >= 3) into centralized domain constants.
- **Algebraic Simplification**: Apply De Morgan's laws and eliminate redundant boolean checks/comparisons.
- **Clean Break & Zero Legacy**: Delete dead code, commented-out blocks, and temporary flags. Never use generic names (`helper`, `processData`, `utils`).

## Decision Gates

| Situation | Action | Tool |
| --- | --- | --- |
| Cold-start or prioritization | Inspect unified Evidence Contract (noise + complexity + blast radius + hash) | `inspect_evidence` (CLI / MCP) |
| Deep nesting (>2) or long inline closures | Audit structural noise & check pass/fail score | `audit_noise` (CLI / MCP) |
| Duplicated literals or compound boolean logic | Analyze DRY extraction candidates & algebraic reductions | `refactor_helper` (CLI / MCP) |
| High cognitive or cyclomatic complexity | Calculate SonarSource Cognitive Complexity per function | `complexity` (CLI / MCP) |
| Modifying public or shared symbols | Measure usage count, definitions, and coupling blast radius | `blast_radius` (CLI / MCP) |
| Refactoring with automated verification | Run test-bracketed refactor with state-lock hash & atomic rollback | `safe_refactor` (CLI / MCP) |
| Custom codebase architectural constraints | Check declarative AST/regex anti-pattern rules | `evaluate_rules` (CLI / MCP) |

## Execution Steps

### 0. Tool Resolution

Execute via native MCP tools (`zero-noise mcp`) when available, or CLI commands via the native `zero-noise` binary:

- **MCP Tools**: `inspect_evidence`, `audit_noise`, `complexity`, `blast_radius`, `safe_refactor`, `refactor_helper`, `evaluate_rules`
- **Native CLI**: `zero-noise audit`, `zero-noise complexity`, `zero-noise blast`, `zero-noise refactor`

### 1. Evidence Inspection & Prioritization
1. `inspect_evidence`: generate a prioritized Evidence Pack sorted by `priority_score` (High Complexity + High Noise + Low Blast Radius = safe quick wins first).
   - MCP: `inspect_evidence(path=target, page=1, page_size=10)`
   - CLI: `zero-noise audit <target> --format=compact`
   - Store `file_hash` as the state lock token for safe delivery.

### 2. Coupling & Safety Validation
2. Evaluate safety condition:
   - `safe_quick_win`: internal/leaf functions with low blast radius; eligible for automated or direct refactor.
   - `requires_signature_validation`: exported symbols or high blast radius; require explicit caller verification before signature changes (`zero-noise blast <symbol>`).

### 3. Spatial Zero-Noise Refactoring
3. Analyze DRY candidates and algebraic reductions isolated strictly within AST node ranges.
   - CLI: `zero-noise refactor <target> --dry-run`
- Invert conditions and apply **Early Return** guards (nesting <= 2).
- Extract argument closures into **pure named functions** passed by reference.
- Name compound boolean expressions with **domain semantic predicates**.
- Centralize repeated literals into **domain constants**.

### 4. State-Locked Safe Delivery & Rollback Protection
4. `safe_refactor`: execute refactoring locked by `expected_hash` and bracketed by tests, complexity gatekeeper, and automatic atomic rollback.
   - MCP: `safe_refactor(filepath=target, expected_hash="...", test_cmd="...")`
   - CLI: `zero-noise refactor <target> --test-cmd "<test-command>" --fix`
- Re-run `zero-noise audit <target>` to confirm structural noise is 0.


## Output Contract

Return:
- **Files Refactored**: target paths and scope.
- **Structural Transformations**: count of guards applied, closures extracted, predicates named, and constants created.
- **Verification Metrics**: noise score (must be 0), cognitive complexity delta, and test suite execution result.
- **Safety Status**: verification of atomic test pass or rollback details if failure occurred.

## References

- `reference/cleanliness_rules.md` — Mandatory standards for inline closures, guard clauses, and boolean logic.
- `reference/architecture_patterns.md` — Domain semantic predicates, DRY constants, and clean break.
- `.zero-noise-rules.json` — Declarative custom anti-pattern rules.
- `.zero-noise.json` — Custom thresholds and directory ignore patterns.
