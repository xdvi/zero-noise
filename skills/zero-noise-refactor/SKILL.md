---
name: zero-noise-refactor
description: "Trigger: refactor code, clean code, DRY, early return, zero-noise, complexity. Refactor code for zero structural noise, flattening nested logic, naming domain predicates, and simplifying boolean expressions across Go, Rust, TS, Python, C#, and Zig."
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

### When NOT to Use
- **Generated or Vendored Code**: Never touch codegen outputs (`*.pb.go`, `*.g.dart`, `dist/`), `vendor/`, or `node_modules/`.
- **Deliberate State Machines / Parsers**: Do not flatten state transitions, lexers, or protocol switches where nested branching models explicit state tables.
- **Unmeasured Hot Paths**: Do not extract closures or predicates in tight loops/hot paths when no benchmark or profiler gate exists to verify zero cost regression.
- **Unvalidated Public APIs**: Never alter exported signatures or shared contracts before running `blast_radius` across all callers.

## Hard Rules

- **Zero Behavior Change**: Preserve exact external behavior, signatures, error types, and API contracts.
- **Evidence → Proposal → `safe_refactor` (No Blind-Fix)**: Never run `--fix` blindly. Inspect evidence, list engine proposals (`propose_fixes` / `zero-noise plan`), preview the diff, propose the scoped change, then execute `safe_refactor` with `expected_hash` and an explicit `patch_kind`.
- **Proposal Flow**: Compose non-overlapping proposals into one candidate before applying. Guard and predicate patches require `test_cmd`; the engine refuses them otherwise. Names marked `naming_required` are placeholders — propose real domain names to the user before applying. Applications must declare `patch_kind`; the engine verifies it against its own proposals when it can and aborts on classification mismatch.
- **One Concern per Pass**: Cap each pass/diff/commit to a single structural concern (e.g., pass 1: guard clauses; pass 2: predicate/closure extraction; pass 3: DRY constants). Keep diffs small and reviewable.
- **Inlining Ban**: Never keep anonymous closures in argument position (the automated engine flags closures exceeding 80 characters via `config.max_closure_len`). Extract pure named functions passed by reference.
- **Absolute Early Return**: Invert conditions and return early. Maximum nesting depth is 2 levels.
- **Ubiquitous Language in Predicates**: Replace compound boolean conditions (`a && (b || c)`) with domain-named predicates that reuse the repository's existing vocabulary. Never synonymize established repo terms; if domain naming is ambiguous, propose candidates and wait for user approval.
- **Short-Circuit & Side-Effect Safety**: Before applying De Morgan's laws or inverting conditions, verify operands have no side-effects, mutations, I/O, or panic/nil/bounds guards dependent on evaluation order. If present, isolate side-effects into prior statements or skip algebraic rewrite.
- **Hot-Path Benchmark Gate**: If the target is a hot path and the repo has benchmarks, measure before and after refactoring (tests verify semantics; benchmarks verify cost).
- **Single Source of Truth (DRY)**: Extract repeated string literals (frequency >= 3) into centralized domain constants.
- **Clean Break & Zero Legacy**: Delete dead code, commented-out blocks, and temporary flags. Never use generic names (`helper`, `processData`, `utils`).

## Decision Gates

| Situation | Action | Tool |
| --- | --- | --- |
| Cold-start or prioritization | Inspect unified Evidence Contract (noise + complexity + blast radius + hash) | `inspect_evidence` (CLI / MCP) |
| Generated/vendored file or deliberate state machine | Abort refactor; leave file untouched | None (Skip) |
| Modifying public or shared symbols | Measure usage count, definitions, and coupling blast radius before any edit | `blast_radius` (CLI / MCP) |
| Ambiguous domain concept for new predicate | Propose predicate name(s) aligned with repo vocabulary; wait for approval | User confirmation |
| Condition contains side-effects, I/O, or nil/bounds guard | Isolate side-effect first or preserve short-circuit guard order; do not blind-apply De Morgan | Manual AST inspection |
| Target is a hot path and repo has benchmarks | Run baseline benchmark before edit and compare after `safe_refactor` | Project benchmark runner |
| Deep nesting (>2) or long inline closures | Audit structural noise & check pass/fail score | `audit_noise` (CLI / MCP) |
| Duplicated literals or pure boolean algebra | Analyze DRY extraction candidates & preview algebraic reductions | `refactor_helper` (CLI / MCP) |
| Findings → applicable patch | List engine proposals with state-lock hashes; compose non-overlapping candidates into one patch | `propose_fixes` / `zero-noise plan` (CLI / MCP) |
| Proposed name is `naming_required` | Placeholder name; propose real domain names to the user before applying | User confirmation |
| High cognitive complexity | Calculate SonarSource Cognitive Complexity per function | `complexity` (CLI / MCP) |
| Applying a reviewed single-concern pass | Run test-bracketed refactor with state-lock hash, explicit `patch_kind`, and atomic rollback (`test_cmd` mandatory for guard/predicate patches) | `safe_refactor` (CLI / MCP) |
| Custom codebase architectural constraints | Check declarative AST/regex anti-pattern rules | `evaluate_rules` (CLI / MCP) |

## Execution Steps

### 0. Tool Resolution

Execute via native MCP tools (`zero-noise mcp`) when available, or CLI commands via the native `zero-noise` binary:

- **MCP Tools**: `inspect_evidence`, `audit_noise`, `complexity`, `blast_radius`, `refactor_helper`, `propose_fixes`, `safe_refactor`, `evaluate_rules`
- **Native CLI**: `zero-noise audit`, `zero-noise complexity`, `zero-noise blast`, `zero-noise plan`, `zero-noise refactor`

### 1. Gate Check & Evidence Inspection
1. Confirm the target is not generated/vendored, a deliberate state machine, or an unbenchmarked hot path.
2. Generate evidence:
   - MCP: `inspect_evidence(path=target, page=1, page_size=10)` generates the full Evidence Pack with `state_lock_sha256` (`expected_hash`).
   - CLI: `zero-noise audit <target> --format=compact` formats structural noise findings compactly (paired with `zero-noise complexity <target> --threshold=15`).

### 2. Blast Radius & Candidate Analysis
3. Check coupling and preview reductions before editing:
   - Exported/shared symbols: run `blast_radius(symbol=...)` / `zero-noise blast <symbol> --root=.` to verify callers.
   - DRY & boolean candidates: run `refactor_helper(filepath=target)` / `zero-noise refactor <target> --dry-run`.
   - If target is a hot path with repo benchmarks, record baseline benchmark metrics now.

### 3. Scoped Proposal (One Concern per Pass)
4. Formulate a single-concern refactor pass:
   - **Guards**: flatten nesting (`<= 2`) with early returns, preserving nil/bounds short-circuit order.
   - **Predicates / Closures**: extract closures (`>2` lines or `>80` chars) and compound booleans into pure functions using the repo's exact domain terms (ask user if naming is ambiguous).
   - **Boolean Algebra**: apply De Morgan only after confirming all operands are pure and panic-free.
   - **DRY Constants**: centralize literals repeated `>= 3` times.
5. Materialize the pass as engine proposals and review them:
   - MCP: `propose_fixes(path=target, kinds="guard", include_patches=true)` returns proposals with `expected_hash`, plus a composed candidate when `compose=true`.
   - CLI: `zero-noise plan <target> --compose` (add `--include-patches` for per-proposal diffs).
   - Proposals with `naming_required=true` carry placeholder names — propose real domain names to the user and wait for approval before applying.
   - Compose non-overlapping proposals into a single candidate; overlapping proposals are reported as conflicts and must be applied in separate passes.

### 4. State-Locked Safe Delivery & Verification
6. Execute the approved pass through `safe_refactor` with state-lock hash, explicit `patch_kind`, and test command:
   - MCP: `safe_refactor(filepath=target, expected_hash="...", test_cmd="...", patch_content="...", patch_kind="guard")`
   - CLI: `zero-noise refactor <target> --expected-hash="<hash>" --test-cmd="<test-cmd>" --patch-file=<patch> --patch-kind=<kind> --fix`
   - The engine verifies `patch_kind` against its own proposals and aborts on classification mismatch. Guard and predicate patches require `test_cmd` — without it the engine refuses to touch the file.
7. Re-run `audit_noise` (`zero-noise audit <target>`) and `complexity` to confirm noise score is `0` and complexity decreased. On hot paths, re-run benchmarks to confirm zero regression.

## Output Contract

Return:
- **Files & Scope Pass**: target path, concern addressed in this pass, and `expected_hash` used.
- **Structural Transformations**: guards applied, closures extracted, domain predicates named, or constants centralized.
- **Verification Metrics**: noise score (must be `0`), cognitive complexity delta, `test_cmd` status, and benchmark delta (when on a hot path).
- **Safety Status**: confirmation of state-locked test pass or atomic rollback details.

## Examples

### GOOD: Guard Clauses + Ubiquitous Language Predicate (Single Pass)
```ts
// Before: deep nesting + raw compound condition; repo uses "Order" and "Fulfillment"
function dispatchOrder(order: Order | null, warehouse: Warehouse): Receipt | null {
  if (order !== null) {
    if (order.isPaid && order.items.length > 0 && warehouse.hasStock(order.id)) {
      return warehouse.fulfill(order);
    }
  }
  return null;
}

// After: early return + predicate preserving repo's "Order"/"Fulfillment" vocabulary
function isReadyForFulfillment(order: Order, warehouse: Warehouse): boolean {
  return order.isPaid && order.items.length > 0 && warehouse.hasStock(order.id);
}

function dispatchOrder(order: Order | null, warehouse: Warehouse): Receipt | null {
  if (order === null || !isReadyForFulfillment(order, warehouse)) return null;
  return warehouse.fulfill(order);
}
```

### BAD: Mechanical Over-Extraction, Synonymization & Broken Short-Circuit
```ts
// Anti-example — DO NOT DO THIS:
// 1. Reorders/applies De Morgan across nil guard & side-effectful consumeQuota()
// 2. Invents synonym "Shipment" instead of repo's "Fulfillment" + generic "Helper" name
function checkShipmentHelper(o: Order | null, w: Warehouse): boolean {
  return !(!w.consumeQuota() || o === null || !o.isPaid); // BUG: mutates quota even when o is null!
}
```

## References

- `reference/cleanliness_rules.md` — Mandatory standards for inline closures, guard clauses, and side-effect-safe boolean logic.
- `reference/architecture_patterns.md` — Ubiquitous language predicates, DRY constants, and clean break.
- `.zero-noise-rules.json` — Declarative custom anti-pattern rules.
- `.zero-noise.json` — Custom thresholds and directory ignore patterns.
