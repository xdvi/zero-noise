# P0 — Applicable-Fix Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn zero-noise findings into machine-applicable patches: an edit engine, AST rewrite passes (guards, constants, predicates, closures) with per-language capability gating, proposal surfaces (`propose_fixes`, `zero-noise plan`), and an engine-enforced apply contract where guard/predicate patches require a test command.

**Architecture:** New `src/mutation/` modules (edits, proposal, propose orchestrator, rewrite passes) produce byte-range `Edit` sets rendered as unified diffs; the existing `safe_refactor` runner gains `patch_content`/`patch_kind` and refuses guard/predicate patches without `test_cmd`. Surfaces are additive: one new MCP tool and one new CLI command, wired through the existing `Deps`/`ToolResult`/format patterns.

**Tech Stack:** Zig 0.17.x, Tree-sitter C ABI (embedded grammars), Zig `std.testing`, existing CLI/MCP plumbing.

**Spec:** `docs/superpowers/specs/2026-10-18-rea-parity-design.md` (phase P0; sections 5, 6-P0, 7, 8).

## Global Constraints

- `zig build test` stays green and leak-free (all tests use `std.testing.allocator`).
- Zero new runtime or build dependencies; grammars and C sources remain embedded and cross-platform (Linux, macOS, Windows).
- Every mutation verifies SHA-256 (`expected_hash`) before writing; guard and predicate patches are rejected without `test_cmd` (engine-enforced).
- Dry-run is the default everywhere; apply requires explicit opt-in (`fix=true` / `--fix`).
- No breaking changes to existing MCP tool names/parameters or CLI flags; additions only.
- Output formats `text`, `json`, `sarif`, `compact`, `evidence` keep their contracts.
- `manifest.json` is the single metadata source; `python3 scripts/sync_manifests.py --check` passes; new surfaces update it in the same commit.
- Deterministic output: identical input yields byte-identical proposals and patches.
- Conventional Commits, no attribution trailers.

## Review Focus

Uncovered failure modes to pin while reading — each has a test in the owning task:

1. File changed between propose and apply: hash lock must abort, never fuzzy-apply. (Task 16)
2. `if` inside loops/switch/catch: must stay advisory — an injected early `return` would change flow. (Tasks 5–8)
3. CRLF files and files without a trailing newline: edits must preserve bytes exactly. (Tasks 1, 5)
4. Determinism: same input → byte-identical JSON/patches, so CI diffs are stable. (Tasks 3, 22)
5. Files with parse errors: no proposals, an advisory limitation is reported, no panic. (Task 3)

---

## File Structure

- `src/mutation/edits.zig` (new) — byte-range `Edit`, apply, sort, overlap detection, multi-proposal merge.
- `src/mutation/proposal.zig` (new) — `Proposal` model, patch preview rendering.
- `src/mutation/propose.zig` (new) — pass orchestration, capability matrix, deterministic ordering, limitations.
- `src/mutation/rewrite_guards.zig` (new) — guard/early-return pass.
- `src/mutation/rewrite_constants.zig` (new) — repeated-literal extraction pass.
- `src/mutation/rewrite_predicates.zig` (new) — compound-boolean predicate extraction pass.
- `src/mutation/rewrite_closures.zig` (new) — long-closure extraction pass.
- `src/mutation/runner.zig` (modify) — `patch_kind`, test enforcement, dry-run defaults.
- `src/mcp/tools/safe_refactor.zig` (modify) — new args pass-through.
- `src/mcp/tools/propose_fixes.zig` (new) — MCP surface.
- `src/mcp/tools/refactor_helper.zig` (modify) — additive proposal counts.
- `src/mcp/protocol.zig`, `src/mcp/app.zig`, `src/mcp/deps.zig`, `src/root.zig` (modify) — registration.
- `src/cli/plan.zig` (new), `src/main.zig` (modify) — CLI surface.
- `manifest.json`, `scripts/sync_manifests.py`, `.github/workflows/ci.yml` (modify) — surface verification.
- `bench/bench.zig` (modify) — proposal-pass benchmarks.
- Docs: `README.md`, `AGENTS.md`, `CHANGELOG.md`, `skills/zero-noise-refactor/`, `commands/`, `agents/` (modify).

---

### Task 1: Edit engine

**Files:**
- Create: `src/mutation/edits.zig`
- Modify: `src/root.zig` (export `edits` under `mutation`)
- Test: inline `test` blocks in `src/mutation/edits.zig`

**Interfaces:**

- Consumes: nothing.
- Produces: `Edit{start: u32, end: u32, replacement: []const u8}`; `apply(allocator, source, edits) ![]u8`; `sortEdits(edits: []Edit) void`; `anyOverlap(edits: []const Edit) bool`; `mergeProposalEdits(allocator, sets: []const []const Edit) ![]Edit` (error `error.ConflictingEdits`); `offsetToPoint(source, offset) struct{ line: u32, col: u32 }`.

- [ ] **Step 1: Write failing tests**

```zig
test "apply replaces byte ranges and validates bounds" { /* "abcdef", edit {1,3,"XY"} -> "aXYdef"; out-of-bounds -> error.OutOfBounds */ }
test "apply rejects overlapping and unsorted edits" { /* two overlapping -> error.OverlappingEdits; "abcdef" edits {3,4},{1,2} -> error.UnsortedEdits */ }
test "mergeProposalEdits combines disjoint sets and flags overlaps" { /* [{1,2},{4,5}] + [{2,3}] ok; {1,3}+{2,4} -> error.ConflictingEdits */ }
test "crlf and missing trailing newline survive apply" { /* source "a\r\nb" + edit on "b" keeps \r\n; source "x" indent edit keeps no-newline */ }
test "offsetToPoint counts lines and columns" { /* offset of 'c' in "ab\ncd" -> line 2 col 1 */ }
```

- [ ] **Step 2: Run `zig build test` — expect compile errors / failures.**

- [ ] **Step 3: Implement `src/mutation/edits.zig`**

Pure Zig, no I/O. `apply` dups `source`, copies segments around sorted non-overlapping edits. `mergeProposalEdits` concatenates all sets, sorts, and errors on any overlap or identical range. `offsetToPoint` returns 1-based line/col.

- [ ] **Step 4: Run `zig build test` — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add src/mutation/edits.zig src/root.zig
git commit -m "feat(mutation): add byte-range edit engine"
```

---

### Task 2: Proposal model

**Files:**
- Create: `src/mutation/proposal.zig`
- Modify: `src/root.zig`
- Test: inline tests

**Interfaces:**

- Consumes: Task 1 (`Edit`, `apply`), `src/mutation/patch.zig` (`generateDiff`).
- Produces:

```zig
pub const ProposalKind = enum { guard, predicate, constant, closure, boolean };
pub const Confidence = enum { high, medium, low };
pub const Proposal = struct {
    kind: ProposalKind,
    rule: []const u8,        // noise rule name, "" for boolean
    file: []const u8,        // path as supplied by the caller
    line: u32, col: u32,     // 1-based
    message: []const u8,
    confidence: Confidence,
    naming_required: bool,
    safe_to_apply: bool,     // false => advisory, edits must be empty
    edits: []Edit,
};
pub fn deinit(self: Proposal, allocator) void;
pub fn kindName(kind: ProposalKind) []const u8;
pub fn patchPreview(allocator, source, p, filename) ![]u8; // "" when !safe_to_apply
```

- [ ] **Step 1: Write failing tests**

```zig
test "patchPreview renders unified diff from edits" { /* source "const s = \"A\";\n" edit replaces "A" with NAME -> diff contains "-const s = \"A\";" and "+const s = NAME;" */ }
test "patchPreview is empty for advisory proposals" { /* safe_to_apply=false, edits={} -> "" */ }
```

- [ ] **Step 2: Run `zig build test` — expect FAIL.**

- [ ] **Step 3: Implement** — `patchPreview` applies edits then calls `patch.generateDiff`, passing the basename. Advisory invariant enforced with `std.debug.assert`.

- [ ] **Step 4: Run `zig build test` — expect PASS.**

- [ ] **Step 5: Commit** — `feat(mutation): add proposal model and patch preview`

---

### Task 3: Proposal orchestrator and capability matrix

**Files:**
- Create: `src/mutation/propose.zig`
- Modify: `src/root.zig`
- Test: inline tests

**Interfaces:**

- Consumes: Task 2, `bindings.getThreadParser`, `grammars.Language`.
- Produces:

```zig
pub const KindFlags = struct { guard: bool = true, predicate: bool = true, constant: bool = true, closure: bool = true, boolean: bool = false };
pub const Capability = enum { enabled, advisory };
pub fn capabilityFor(kind: ProposalKind, lang: grammars.Language) Capability; // advisory until a pass task enables the pair
pub const PassFn = *const fn (std.mem.Allocator, []const u8, grammars.Language, bindings.TSNode) anyerror![]proposal.Proposal;
pub const CollectResult = struct { proposals: []proposal.Proposal, limitations: [][]const u8, parse_error: bool };
pub fn collectProposals(allocator, source, lang, flags: KindFlags) !CollectResult;
pub fn deinitCollectResult(allocator, *CollectResult) void;
```

- [ ] **Step 1: Write failing tests**

```zig
test "unknown language returns empty result with limitation" { /* lang .unknown -> 0 proposals, limitations.len == 1 */ }
test "parse-error file reports parse_error and no proposals" { /* TS source "const x = ;" -> parse_error == true, proposals.len == 0 */ }
test "proposals sort deterministically by line, col, kind name" { /* feed two synthetic passes via test hook; assert order stable across 2 runs */ }
test "advisory capability adds a limitation entry" { /* capabilityFor(.predicate, .go) == .advisory on this task's state */ }
```

- [ ] **Step 2: `zig build test` — expect FAIL.**

- [ ] **Step 3: Implement** — parse once with the thread parser; run enabled passes whose capability is `enabled`; for `advisory` pairs append `"<kind> extraction not enabled for <lang> (advisory)"` to `limitations`; sort proposals by `(line, col, kindName, rule)`; deduplicate identical `(kind, line, col)`.

- [ ] **Step 4: `zig build test` — PASS.**

- [ ] **Step 5: Commit** — `feat(mutation): add proposal orchestrator and capability matrix`

---

### Task 4: Manifest surface verification

**Files:**
- Modify: `manifest.json` (add `"cli_commands": [...]`, `"mcp_tools": [...]`), `scripts/sync_manifests.py`, `.github/workflows/ci.yml`
- Test: script self-check via `--check`

**Interfaces:**
- Produces: `sync_manifests.py --check` verifies: `mcp_tools` equals the `name` fields in `src/mcp/protocol.zig` `TOOLS`; `cli_commands` equals the subcommands listed in `src/main.zig` usage text. Exit 1 with a diff-style report on mismatch.

- [ ] **Step 1: Add failing check** — extend the script with a `verify_surfaces()` function; run `python3 scripts/sync_manifests.py --check` before updating `manifest.json`; expect failure listing missing `plan`/`propose_fixes`? (Not yet — on this task, populate both lists from current reality: 7 tools, 5 commands. The check must fail when a list entry is removed.)
- [ ] **Step 2: Verify the check fails on a deliberate mismatch** (temporarily remove one entry, run, restore).
- [ ] **Step 3: Add the CI step** `python3 scripts/sync_manifests.py --check` to the test job in `.github/workflows/ci.yml`.
- [ ] **Step 4: Run `python3 scripts/sync_manifests.py --check` plus `zig build test` — both PASS.**
- [ ] **Step 5: Commit** — `ci: verify CLI and MCP surface lists against manifest`

---

### Task 5: Guard pass — core + TypeScript/TSX

**Files:**
- Create: `src/mutation/rewrite_guards.zig`
- Modify: `src/mutation/propose.zig` (register pass; set capability for `typescript`, `tsx`)
- Test: inline tests

**Interfaces:**
- Consumes: Task 3 (`PassFn`).
- Produces: `pub fn collect(allocator, source, lang, root: bindings.TSNode) ![]proposal.Proposal`; internal `GuardSyntax` table per language:

```zig
const GuardSyntax = struct {
    if_nodes: []const []const u8,   // e.g. {"if_statement"}
    condition_field: []const u8,
    body_field: []const u8,
    else_field: []const u8,         // empty when the grammar has no else field
    early_return: []const u8,       // "{ return; }" TS/Go/C#/Zig/Rust, "return" Python
    invert_prefix: []const u8,      // "!" or "not "
};
```

**V1 transform (pin these rules):** an `if` node with no else, whose parent chain up to the enclosing function contains no loop, switch, catch, or closure node, inside a void-returning function, where:
- the body is non-empty, contains no comments, and no multi-line string literal;
- for TS/TSX the enclosing function is `function_declaration`/`method_definition`/`variable_declarator` arrow or expression with an explicit `: void` return type or no annotation on arrow expressions only when the body has no value returns — otherwise advisory.

Transform emits one edit replacing the whole `if` node with `if <invert>(<cond>)<space><early_return>` + newline + body de-indented by one level. Indentation unit = first non-blank body line's prefix minus the `if` line's prefix; every non-blank body line must start with it; CRLF line endings and a missing trailing newline are preserved.

When two eligible `if`s nest, keep the innermost; the outer becomes eligible on the next plan cycle.

**Expected TS behavior (exact):**

```ts
function process(user: User): void {
  if (user.isActive) {
    sendEmail(user);
  }
}
// becomes
function process(user: User): void {
  if (!(user.isActive)) { return; }
  sendEmail(user);
}
```

- [ ] **Step 1: Failing tests** (inline, one per rule):

```zig
test "guard extraction flattens void function" { /* input/expected exactly as above */ }
test "non-void function stays advisory" { /* "): string {" -> 0 proposals or safe_to_apply == false */ }
test "if inside loop stays advisory" { /* if inside for -> advisory */ }
test "if with else stays advisory" }
test "if containing comments stays advisory" }
test "multi-line string in body stays advisory" }
test "CRLF input keeps CRLF and missing trailing newline preserved" }
test "nested eligible ifs keep only the innermost" }
test "comment-only or empty body stays advisory" }
```

- [ ] **Step 2: `zig build test` — expect FAIL.**

- [ ] **Step 3: Implement** — walk named nodes via `root` cursor; a probe test first asserts `childByFieldName` lookups resolve on a TS sample (adjust `GuardSyntax` constants if field names differ). Build replacement text with `std.ArrayList(u8)`; create the edit from `node.startByte()`/`node.endByte()`; `line/col` from `node.startPoint()`. Proposal: `kind=.guard`, `rule="excessive-nesting"`, `confidence=.medium`, `naming_required=false`, `safe_to_apply=true`.

- [ ] **Step 4: `zig build test` — PASS.**

- [ ] **Step 5: Commit** — `feat(mutation): add guard extraction pass for TypeScript`

---

### Task 6: Guard pass — Go and Zig

**Files:**
- Modify: `src/mutation/rewrite_guards.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- Consumes: Task 5 structure; adds `GuardSyntax` rows. Go: `if_statement`, early return `{ return }`, void = no `result` field on `function_declaration`/`method_declaration`. Zig: `if_statement` (statement position only — skip `if_expression` assigned to values), early return `{ return; }`, void = return type absent or `void`.
- Produces: capability `enabled` for `.go` and `.zig`.

- [ ] **Step 1: Failing tests** — one exact input/expected pair per language, plus loop-contained → advisory and non-void → advisory, mirroring Task 5.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement** the two table rows plus any grammar-specific body detection (probe test first).
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add guard extraction for Go and Zig`

---

### Task 7: Guard pass — Rust and Python

**Files:**
- Modify: `src/mutation/rewrite_guards.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- Rust: `if_expression` in statement position; void = `function_item` without `return_type`; early return `{ return; }`; skip when any ancestor is `closure_expression`, `match_expression`, or a loop.
- Python: `if_statement`/`elif_clause` NOT allowed as the guarded node when it has siblings forming an `elif` chain; all functions are void-capable (`return` valid); early return `return`; indentation-based body de-indent handles tabs and spaces; skip if body contains multiline strings or comments.

- [ ] **Step 1: Failing tests** — exact input/expected per language; `elif` chain → advisory; Rust `match` arm → advisory.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.** Python expected behavior:

```python
def process(user):
    if user.is_active:
        send_email(user)
# becomes
def process(user):
    if not (user.is_active): return
    send_email(user)
```

- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add guard extraction for Rust and Python`

---

### Task 8: Guard pass — C#

**Files:**
- Modify: `src/mutation/rewrite_guards.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- C#: `if_statement`; void = `method_declaration`/`local_function_statement` `type` child is `void`; early return `{ return; }`; skip when ancestor chain includes `lambda_expression`, `switch_statement`, loops, or `try_statement` catch parts.

- [ ] **Step 1: Failing tests** — exact input/expected; `async Task` method → advisory; `finally` block containment → advisory.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add guard extraction for C#`

---

### Task 9: Constants pass — TypeScript and Python

**Files:**
- Create: `src/mutation/rewrite_constants.zig`
- Modify: `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**

- Consumes: Task 3.
- Produces: `pub fn collect(allocator, source, lang, root) ![]proposal.Proposal`; internal `LiteralSyntax` table: node types per language (`string`, `number` for TS; `string`, `integer` for Python; `template_string` without substitutions counts as string), declaration template, insertion strategy.

**Rules (pin):** literal text (exact slice) occurring ≥3 times in one file; skip occurrences whose ancestor chain includes import/export statements, decorators/annotations, case/pattern labels, or docstrings (Python first statement of a scope). Name: uppercase the sanitized literal (letters/digits, `_` separators; empty or digit-leading → `L_` prefix; truncate at 40 chars); collision with any identifier/property identifier in the file appends `_2`, `_3`. Insertion: after the last import statement (Python) / after the last top-level import declaration (TS); else at file start. Proposal: `kind=.constant`, `rule="repeated-literal"`, `naming_required=true`, `safe_to_apply=true`, `confidence=.high`; edits = insertion edit + one replace edit per occurrence.

- [ ] **Step 1: Failing tests:**

```zig
test "extracts literal repeated three times in TypeScript" { /* const A = "ACTIVE"; inserted after imports; 3 occurrences replaced */ }
test "two occurrences stay untouched" }
test "literal in import path is excluded" }
test "name collision appends suffix" }
test "python docstring occurrence excluded" }
test "python declaration inserted after imports with no type annotation" }
```

- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement** with a probe test verifying literal node types per grammar.
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add constant extraction for TypeScript and Python`

---

### Task 10: Constants pass — Go and Zig

**Files:**
- Modify: `src/mutation/rewrite_constants.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- Go: `const NAME = "value"` inserted after the last top-level `import` declaration; literal nodes are `interpreted_string_literal`, `raw_string_literal`, `int_literal`, `float_literal`, `true`/`false` identifiers excluded.
- Zig: `const NAME = "value";` inserted after the last top-level declaration containing `@import`; nodes `string` (string literal), `integer`.

- [ ] **Step 1: Failing tests** — exact declaration placement per language; bool literals excluded.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add constant extraction for Go and Zig`

---

### Task 11: Constants pass — Rust (strings only) and C#

**Files:**
- Modify: `src/mutation/rewrite_constants.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- Rust: only `string_literal` (type `&str`). Declaration `const NAME: &str = "value";` inserted after the last `use` declaration. Integer/float literals stay advisory (type synthesis unsafe in v1).
- C#: `const string NAME = "value";` / `const int NAME = 42;` / `const bool NAME = true;` inserted inside the class (`class_declaration` body) containing all occurrences; occurrences spanning multiple classes → advisory.

- [ ] **Step 1: Failing tests** — Rust int literal → advisory; C# multi-class → advisory; C# single-class placement exact.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add constant extraction for Rust and C#`

---

### Task 12: Predicate pass — TypeScript/TSX

**Files:**
- Create: `src/mutation/rewrite_predicates.zig`
- Modify: `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**

- Consumes: Task 3.
- Produces: `pub fn collect(...)`; capability `enabled` for `typescript`/`tsx`, advisory elsewhere.

**V1 allowlist (pin):** a condition node (from `if` statements) that is a same-operator chain (`&&` only, or `||` only) with 2+ operands; each operand is an identifier or property chain (no calls, literals, `await`, assignments, or `this`); every root identifier resolves to a nearby declaration with an explicit type annotation (parameter or variable_declarator `type`); condition used once in the file. Emit `function <name>(<params>): boolean { return <cond>; }` immediately before the enclosing function declaration, and replace the condition with `<name>(<args>)`. Placeholder name: `is` + PascalCase(first root identifier), collision-suffixed; `naming_required=true`. `kind=.predicate`, `rule="raw-boolean"`, `confidence=.medium`, `safe_to_apply=true`.

- [ ] **Step 1: Failing tests:**

```zig
test "extracts sorted-and-two-flag condition with annotated params" { /* function isReadyFor(user: User): boolean { return user.isActive && user.hasPaid; } */ }
test "mixed && and || stays advisory" }
test "operand with function call stays advisory" }
test "unannotated parameter stays advisory" }
test "this-based operand stays advisory" }
test "name collision appends suffix" }
```

- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add predicate extraction for TypeScript`

---

### Task 13: Predicate pass — Python

**Files:**
- Modify: `src/mutation/rewrite_predicates.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- Python: same allowlist; operands are identifiers/attribute chains; no types needed; emit

```python
def is_ready(user):
    return user.is_active and user.has_paid
```

inserted immediately before the enclosing `function_definition`, condition replaced with `is_ready(user)`. `naming_required=true`, kind/rule/confidence as Task 12.

- [ ] **Step 1: Failing tests** — exact module/def shape; `await` operand → advisory; mixed operators → advisory.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add predicate extraction for Python`

---

### Task 14: Closure pass — TypeScript/TSX

**Files:**
- Create: `src/mutation/rewrite_closures.zig`
- Modify: `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**

- Consumes: Task 3.
- Produces: `pub fn collect(...)`; capability `enabled` for `typescript`/`tsx`.

**V1 allowlist (pin):** `arrow_function`/`function_expression` inside call `arguments` whose slice exceeds 80 chars, no `this` node in the body, no `await`/`yield` in the body. Emit a `function <name>(<params>) { <body> }` declaration immediately before the statement that contains the closure (expression body becomes `return <expr>;`), and replace the closure with the name. Placeholder `extractedClosure<N>` collision-suffixed; `naming_required=true`; `kind=.closure`, `rule="long-closure"`, `confidence=.medium`, `safe_to_apply=true`.

- [ ] **Step 1: Failing tests** — extraction exact shape; `this` usage → advisory; closure under 80 chars → no proposal; closure not in argument position → no proposal; statement-level insertion point.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add closure extraction for TypeScript`

---

### Task 15: Closure pass — Python

**Files:**
- Modify: `src/mutation/rewrite_closures.zig`, `src/mutation/propose.zig`
- Test: inline tests

**Interfaces:**
- Python: `lambda` in argument position longer than 80 chars; emit `def name(<params>):\n    return <expr>` immediately before the containing statement at its indentation level; replace lambda with `name`. `naming_required=true`; kind/rule/confidence as Task 14.

- [ ] **Step 1: Failing tests** — exact def shape and indentation; lambda assigned to a variable (not argument position) → no proposal.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): add closure extraction for Python`

---

### Task 16: Apply contract — `patch_content`, `patch_kind`, test enforcement, dry-run defaults

**Files:**
- Modify: `src/mutation/runner.zig`, `src/mcp/tools/safe_refactor.zig`, `src/mcp/protocol.zig`, `src/cli/refactor.zig`
- Test: inline tests in `runner.zig`, `safe_refactor.zig`, `app.zig`

**Interfaces:**

- Consumes: Task 2 (`ProposalKind` names), existing `executeSafeRefactor`.
- Produces:
  - `PatchSource{ candidate_content: ?[]const u8, patch_file: ?[]const u8, patch_content: ?[]const u8, patch_kind: ?[]const u8 }`.
  - `executeSafeRefactor` behavior: when `fix=true` and `patch_kind` is `"guard"` or `"predicate"` and `test_run.test_cmd == null` → `status=.aborted`, `error_msg` contains `"test_cmd required for guard/predicate patches"`, file untouched. Dry-run (`fix=false`) previews without the requirement. Hash mismatch still aborts first.
  - MCP `safe_refactor` schema gains `patch_content` (string) and `patch_kind` (enum guard/predicate/constant/closure/boolean); `fix` defaults to `false` (dry-run) — description updated to state apply requires explicit `fix=true`.
  - CLI `refactor` gains `--patch-file=<path>` and `--patch-kind=<kind>`; `--fix` remains the explicit apply opt-in.

- [ ] **Step 1: Failing tests:**

```zig
test "guard patch without test_cmd aborts untouched" { /* status aborted, error contains "test_cmd required", file bytes unchanged */ }
test "guard patch with passing test_cmd applies" { /* test_cmd = "zig version" */ }
test "dry-run previews guard patch without test_cmd" { /* status dry_run, diff non-empty, file unchanged */ }
test "hash mismatch aborts before enforcement" { /* wrong expected_hash + guard kind without test_cmd -> "state lock failed" */ }
test "mcp safe_refactor fix defaults to dry-run" { /* no fix arg -> status dry_run */ }
test "patch_content applies through MCP" { /* patch without context lines applies via patch.applyPatch */ }
```

- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement** — extend `PatchSource` and candidate selection order: `candidate_content` → `patch_content` → `patch_file` → rewriter; enforcement before `applyCandidate`, after hash check. Update protocol schema strings; update `parseArgs` default `getBoolArg(args, "fix", false)`.

- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mutation): enforce test brackets for guard and predicate patches`

---

### Task 17: `propose_fixes` MCP tool

**Files:**
- Create: `src/mcp/tools/propose_fixes.zig`
- Modify: `src/mcp/protocol.zig` (add tool), `src/mcp/app.zig` (dispatch), `src/mcp/deps.zig` (add `collectProposals` fn field defaulting to `propose.collectProposals`), `src/root.zig`, `manifest.json`
- Test: inline tests in `propose_fixes.zig` and `app.zig`

**Interfaces:**

- Consumes: Task 3 (`collectProposals`), Task 16 not required.
- Produces: tool `propose_fixes` with args `path` (file or directory, required), `kinds` (CSV, default all), `include_patches` (bool, default false), `page` (default 1), `page_size` (default 10), `root` (default "."). JSON result:

```json
{"schema":1,"proposals":[{"kind":"guard","rule":"excessive-nesting","file":"...","line":3,"column":5,"message":"...","confidence":"medium","naming_required":false,"safe_to_apply":true,"patch":"..."}],"page":1,"page_size":10,"total":4,"totals_by_kind":{"guard":2},"limitations":["..."],"capabilities":{"guard":true}}
```

Directories: walk via `common.collectSourceFiles`, sort file list before processing. Never silently truncate: `total` always present. Compact format: one line per proposal `[FIX] file:line:col kind confidence naming=? apply=?`.

- [ ] **Step 1: Failing tests:**

```zig
test "propose_fixes returns paged proposals for a fixture file" { /* guard fixture -> total>=1, kind guard */ }
test "include_patches false omits patch field" }
test "directory path aggregates and sorts files deterministically" }
test "unknown kinds argument is ignored with limitation" }
```

- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement** following `audit_noise.zig` patterns (`ToolResult`, `common.getStringArg`). Register in `protocol.TOOLS`, `app.zig` table, `root.zig` imports and test block.
- [ ] **Step 4: `python3 scripts/sync_manifests.py --check` and `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mcp): add propose_fixes tool`

---

### Task 18: CLI `plan` command

**Files:**
- Create: `src/cli/plan.zig`
- Modify: `src/main.zig` (route + usage), `src/root.zig`
- Test: inline tests

**Interfaces:**

- Consumes: Task 3.
- Produces: `zero-noise plan <path> [--kinds=guard,constant] [--include-patches] [--page=N] [--page-size=N] [--format=text|json|compact] [--root=PATH]`; exit 0 on success (proposals do not fail the command), 1 on errors or missing path.

- [ ] **Step 1: Failing tests** — mirror `cli/audit.zig` test style: fixture file returns code 0 and output contains `[FIX]`; empty args returns 1; `--format=json` parses.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement**; add `plan` to the usage text in `main.zig`.
- [ ] **Step 4: `python3 scripts/sync_manifests.py --check` and `zig build test` — PASS (manifest `cli_commands` gains `plan`).**
- [ ] **Step 5: Commit** — `feat(cli): add plan command`

---

### Task 19: `refactor_helper` additive proposal summary

**Files:**
- Modify: `src/mcp/tools/refactor_helper.zig`
- Test: inline tests

**Interfaces:**
- Consumes: Task 3.
- Produces: unchanged tool contract; response text gains one line, e.g. `Proposals: guard=1 constant=2 (run propose_fixes or plan for patches).` Existing lines unchanged.

- [ ] **Step 1: Failing test** — fixture with a guard proposal contains `Proposals: guard=1`; existing repeated-literal line unchanged.
- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `feat(mcp): summarize proposals in refactor_helper`

---

### Task 20: Docs, skill, and changelog

**Files:**
- Modify: `README.md` (plan, propose_fixes, patch_content/patch_kind, dry-run default), `AGENTS.md` (tool/command tables + descriptions), `CHANGELOG.md` (Unreleased section), `skills/zero-noise-refactor/SKILL.md` (proposal flow: propose → rename when `naming_required` → apply), `commands/zero-noise.md`, `agents/zero-noise-refactor.md`
- Test: `python3 scripts/sync_manifests.py --check`; verify `propose_fixes` and `plan` documented

**Interfaces:**
- Produces: documentation that matches the shipped surfaces; skill flow statement: "Guard and predicate patches require `test_cmd`; the engine refuses them otherwise. Names marked `naming_required` are placeholders — propose names to the user before applying."

- [ ] **Step 1: Update files.**
- [ ] **Step 2: `python3 scripts/sync_manifests.py --check` — PASS; grep docs for `propose_fixes` and `zero-noise plan` — both present.**
- [ ] **Step 3: Commit** — `docs: document proposal workflow and new surfaces`

---

### Task 21: Benchmarks for proposal passes

**Files:**
- Modify: `bench/bench.zig`
- Test: `zig build bench`

**Interfaces:**
- Produces: bench cases measuring `collectProposals` over `tests/fixtures/dirty/*` (all four rule kinds); results recorded like existing cases.

- [ ] **Step 1: Add bench cases.**
- [ ] **Step 2: `zig build bench` — runs to completion, timings printed.**
- [ ] **Step 3: Commit** — `perf(bench): add proposal-pass benchmarks`

---

### Task 22: End-to-end and determinism tests

**Files:**
- Modify: `src/mcp/app.zig` (integration test)
- Test: inline test

**Interfaces:**
- Consumes: Tasks 16, 17.
- Produces: one end-to-end test proving the full loop.

- [ ] **Step 1: Write failing test:**

```zig
test "propose then apply guard patch end to end" {
    // 1. write tests/tmp_guard_e2e.ts with the Task 5 input shape
    // 2. propose_fixes (include_patches=true) -> take proposals[0].patch
    // 3. safe_refactor with patch_content + patch_kind=guard, no test_cmd -> isError true, file unchanged
    // 4. safe_refactor with test_cmd="zig version" -> applied, file equals expected output
    // 5. propose_fixes twice -> byte-identical JSON (determinism)
}
```

- [ ] **Step 2: `zig build test` — FAIL.**
- [ ] **Step 3: Implement the test; fix any surfaced inconsistency in earlier tasks.**
- [ ] **Step 4: `zig build test` — PASS.**
- [ ] **Step 5: Commit** — `test(mcp): end-to-end propose and apply with determinism check`

---

## Self-Review Notes

- Spec coverage: edit engine (Task 1), proposal model (2), orchestrator/capabilities/limitations (3), four passes (5–15), composition via `mergeProposalEdits` (1) exercised in 16–22, apply contract incl. `patch_kind` enforcement (16), `propose_fixes` (17), `plan` (18), `refactor_helper` compat (19), docs/skill/manifest (4, 20), bench (21), acceptance incl. determinism, CRLF, loop-advisory, parse-error, hash-mismatch, e2e (Tasks 1–3, 5–8, 16, 22).
- Advisory downgrade for predicate/closure languages beyond TS/Python is intentional in P0 (spec §6 P0, naming/typing downgrade rule); the capability matrix and limitations output make it visible.
- Type consistency: `Proposal.edits: []Edit` (Task 1 type), `PassFn` signature identical across Tasks 5/7/9/12/14, `patch_kind` strings match `ProposalKind` names.
