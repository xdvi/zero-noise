# Design: REA-Parity Utility for zero-noise

**Status:** Draft — awaiting user approval
**Date:** 2026-10-18
**Owner:** David (xdvi)
**Repository:** `zero-noise` (verified at HEAD `9cd7020`)

## 1. Intent and why

`zero-noise` is a native Zig engine that audits structural code noise and applies
transactional refactors across Go, Rust, TypeScript, Python, C#, and Zig. It ships as a
CLI, an MCP server, and a plugin for four agent harnesses.

The goal is **utility parity with REA for the refactoring domain**: zero-noise should
be as complete and dependable for "reduce boilerplate and improve readability" as REA
is for reverse engineering.

REA feels complete because of four properties. This roadmap translates each into
refactoring terms:

| REA property | Refactoring equivalent |
| --- | --- |
| Sessions and persistent state | Repo-scale runs, history, reproducible evidence |
| Evidence with coverage and limitations | Every result states what was analyzed, skipped, unsupported, and uncertain |
| Workflow verbs (analyze → compare → correlate → export) | Audit → rank → plan → apply → verify → compare |
| Broad substrate coverage | More languages and more rule depth per language |

"Utility parity" is therefore defined as product behavior, not tool count:

1. An agent can audit a whole repository, rank hot spots, produce a refactor plan,
   apply it under tests, and prove no regression without leaving the tool loop.
2. Findings are actionable: each one can carry a machine-applicable patch with an
   explicit confidence level.
3. Every result declares its scope and limitations; silence is never ambiguous.
4. Every application is state-locked and syntax-validated by the engine; guard and
   predicate patches additionally require a test command, enforced by the engine
   itself.
5. CI can gate refactor quality from a portable artifact (no-regression, not score 0).

## 2. Goals, non-goals, anti-goals

**Goals** — the approved order; each phase is independently shippable:

- **G1 (P0):** Findings become applicable patches. The engine rewrites guards,
  predicates, and repeated literals, not only boolean algebra.
- **G2 (P0.5):** Repo-scale evidence: inventory, ranking, baselines, regression diffs,
  and uniform coverage/limitations reporting.
- **G3 (P1):** Detector depth for real boilerplate: structural clones, dead code,
  unused symbols.
- **G4 (P2):** Language breadth beyond the current six.
- **G5 (P2.5):** Real persistence and history (the current state layer is an
  in-memory stub).

**Non-goals** for this roadmap:

- No daemon, watch mode, or LSP server. zero-noise stays an on-demand CLI + MCP stdio
  process; state lives in files or an embedded database.
- No hosted service, telemetry, or network dependency.
- No GUI.
- No generic lint-rule platform. `evaluate_rules` is frozen for compatibility; it does
  not grow.
- No new runtime dependencies. The binary stays standalone.
- No transforms that change observable behavior; refactors stay structural.
- No breaking changes to existing MCP tool names, parameters, or CLI flags. New
  surfaces are additive.

**Anti-goals** — outcomes that technically work but fail the goal:

- False-positive floods that make agents distrust findings.
- Silent truncation or capping of findings.
- Token-heavy outputs that burn agent context.
- Claims not backed by the build (docs drift, stale binaries).
- "Noise score 0" as a success metric; the criterion is no-regression plus trend.
- Any blind mutation path without a hash lock and syntax validation; guard and
  predicate patches never apply without a test command.

## 3. Constraints

Inherited from `COLLABORATION.md` and the existing engine spec:

- Zero external runtime dependencies; static cross-platform binaries.
- Tree-sitter and any storage engine remain embedded C sources compiled by `zig build`
  (the SQLite amalgamation is already vendored at `c/sqlite3.c`).
- All mutations verify disk state via SHA-256 before writing.
- Leak-free memory; `zig build test` must pass without leaks.
- Cross-platform parity (Linux, macOS, Windows).
- Metadata is centrally managed in `manifest.json` and synchronized via
  `python3 scripts/sync_manifests.py`; CI must run `--check`.
- Conventional Commits; no attribution trailers.

## 4. Current state (verified 2026-10-18, HEAD `9cd7020`)

- ~9.3k lines of Zig. Modules: `analysis/` (noise, complexity, blast),
  `mutation/` (rewriter, runner, patch, syntax, test runner), `storage/`
  (db, ledger), `mcp/` (server, app, protocol, formats, 7 tools), `cli/`,
  `treesitter/` (bindings, grammars), `bench/`.
- Language support: six embedded grammars (Go, Rust, TS/TSX, Python, C#, Zig).
  README, AGENTS.md, and manifest.json advertise five and omit Zig; the grammar is
  compiled and mapped, so only documentation is missing.
- Noise rules: excessive nesting, long closures, redundant ternaries, repeated
  literals, raw compound booleans, commented-out code. Cognitive complexity follows
  SonarSource. Blast radius classifies symbol definitions and references.
- Mutation layer: text-based rewrite passes for redundant ternaries, De Morgan, and
  double negation, run to a fixpoint with cycle detection. No AST rewrites for guard
  clauses, predicate extraction, or constant extraction.
- `safe_refactor`: workspace confinement, SHA-256 state lock, optional syntax
  validation, optional test command, atomic rename, rollback, dry-run, and
  candidate/patch input. The safety pipeline is solid; the proposal side is thin.
- MCP exposes 7 tools. Output formats: text, json, sarif, compact, evidence.
  `inspect_evidence` returns a per-file pack with hash, metrics, and pagination.
- `audit` accepts multiple paths and directories and exits nonzero on findings, but
  there is no repo aggregate, ranking, baseline, or trend.
- Defaults disagree: `safe_refactor` defaults `fix=true` over MCP, while the CLI
  defaults to dry-run. `--fix` can apply rewrites without a test command.
- Persistence is a stub: `storage/db.zig` is in-memory maps, `getSqliteVersion()`
  returns `"no-sqlite"`, the version string is hardcoded `(no-sqlite)`, and
  `c/sqlite3.c` is not compiled. The ledger does not survive process exit. The
  tracked `bin/zero-noise` is stale and reports SQLite 3.46.0. README/CHANGELOG/spec
  still describe SQLite WAL storage.
- Tests: roughly 102 Zig test blocks; the bench harness measures speed, not quality.

## 5. Approved direction and cuts

The user approved the phase order **P0 → P0.5 → P1 → P2 → P2.5** on 2026-10-18.

Cuts and reframings:

- **`--fix` is folded into the safe flow.** Dry-run becomes the default everywhere.
  Applying engine-generated changes requires explicit opt-in (`fix=true` /
  `--fix`), and the hash lock and syntax validation remain mandatory, with the
  guard/predicate test requirement landing in P0. No separate blind path.
- **`evaluate_rules` is frozen.** Kept for compatibility; no new work.
- **"Score 0" is retired as an acceptance criterion.** Replaced by no-regression
  (baseline diff) and trend visibility.

## 6. Phases

### P0 — Applicable-fix engine (highest utility jump)

**Problem:** the engine gives advice and verifies manual work, but only boolean algebra
is machine-applicable. Guard clauses, predicates, and constants are left to the agent.

**Deliverables:**

1. **Edit engine** (`src/mutation/edits.zig`): byte-range edits with provenance
   (rule, location, confidence). Deterministic, idempotent, and applied through the
   existing candidate pipeline. Multiple proposals per file compose into one
   candidate when edits do not overlap; overlaps are flagged; any successful apply
   changes the file hash, invalidates sibling proposals, and forces a re-plan.
2. **AST rewrite passes** (new modules under `src/mutation/`) mapped to existing
   rules:
   - `rewrite_guards.zig` (excessive nesting): flatten nesting with early returns for
     provably safe shapes. Skip if/else chains, loop control flow, labels, or
     deferred cleanup that would change evaluation order.
   - `rewrite_constants.zig` (repeated literal): extract literals repeated at least
     three times into a declaration and replace occurrences. Suggested names are
     mechanical; the proposal is marked `naming_required`.
   - `rewrite_predicates.zig` (raw boolean): extract compound boolean conditions into
     named functions with placeholder names, marked `naming_required`; only for
     operands without side effects or short-circuit-dependent behavior.
   - `rewrite_closures.zig` (long closure): extract inline closures past the length
     threshold into named functions with placeholder names; ships last within P0.
   - Commented-out code stays advisory; no auto-patch.
   - Extraction placement: same file only; nearest common enclosing scope; private
     visibility, never exported; collision-checked names. When a name or type cannot
     be synthesized safely, the proposal downgrades to advisory instead of
     applicable.
3. **Proposal model:** every finding can carry `confidence` (high/medium/low),
   `patch` (unified diff), `naming_required`, `safe_to_apply`, and the source file's
   SHA-256 at proposal time (`expected_hash`), so applications always lock against the
   planned revision. Non-overlapping proposals compose into a single candidate;
   overlaps are listed as conflicts. Emitted on demand, not by default, to keep agent
   output token-frugal.
4. **Surfaces:**
   - CLI: `zero-noise plan <path>` (dry-run proposals; text/json/compact).
   - MCP: new `propose_fixes` tool (file or root; paginated; patches opt-in).
   - `refactor_helper` stays contract-compatible and now references proposals.
5. **Apply:** `safe_refactor` accepts `candidate_content`, `patch_file`, and (new,
   additive) `patch_content` and `patch_kind`, with hash lock, syntax validation,
   and rollback. Applying a patch requires an explicit `patch_kind` (omitted or
   unknown values are rejected); a patch that exactly reproduces an engine proposal
   must declare its true kind, and mismatches abort. Tests stay optional for boolean,
   constant, and closure transforms; guard and predicate patches are rejected
   without a `test_cmd` — enforced by the engine, not only by the skill workflow.

**Acceptance:**

- Each pass ships fixtures for every language it enables, with a documented
  advisory fallback where naming or typing cannot be synthesized; patched code
  parses; fixture test suites pass when present.
- Proposals are deterministic for identical input.
- Unsafe shapes are skipped with a recorded limitation, never emitted as patches.
- Existing tools keep their signatures; `zig build test` is green and leak-free.
- Applying a guard or predicate patch without a `test_cmd` is refused by the engine.

### P0.5 — Repo evidence, baselines, and limitations

**Problem:** results are per file; there is no inventory, ranking, or regression gate,
and tool results do not declare their scope.

**Deliverables:**

1. **`zero-noise report [root]`** and MCP **`repo_report`**:
   - Deterministic JSON, schema version 1: tool version, config, files (path,
     language, loc, sha256, findings by rule, max complexity), aggregates, ranking by
     normalized score, and a limitations block.
   - Deterministic ordering; no timestamp by default (`--stamp` optional) so artifacts
     diff cleanly. Paths are root-relative with `/` separators; the identity hash is
     computed over LF-normalized content so baselines survive CRLF checkouts.
   - MCP returns a ranked summary with explicit totals and pagination plus drill-down,
     never a silent cap; the CLI owns the full artifact.
   - SARIF output for CI annotations.
2. **Baseline artifacts (portable files, CI-friendly):**
   - `zero-noise baseline write --out <file>` and
     `zero-noise baseline check --baseline <file> [--report <file>]`.
   - Policy in `.zero-noise.json`: per-rule gates, per-path ignores, new-file policy
     (exempt by default, strict opt-in).
   - Exit codes: 0 clean, 1 regression or error.
3. **Limitations discipline:** every result declares analyzed, skipped, unsupported,
   and parse-error scope, plus per-language rule applicability.
4. **Advisory multi-file planning:** proposals can be grouped per repo in the report
   and in `plan --root`. Cross-file atomic apply is not part of this phase.
5. **Inventory contract:** `.zero-noise.json` gains include/exclude keys; defaults
   keep today's walker behavior (dot-directories skipped, current build-directory
   ignores); symlinks are not followed; config is auto-discovered at the project root
   and an explicit `--config` overrides it. Behavior changes are listed in the
   CHANGELOG.

**Acceptance:**

- Byte-identical report on unchanged trees.
- A seeded regression fails the check; an unchanged tree passes.
- An agent can answer "what is the noisiest module" and "did this change raise noise"
  using only CLI/MCP.
- No dependency on persistence; works before P2.5.

### P1 — Detector depth

**Problem:** current rules target surface structure; the boilerplate users mean is
structural duplication, dead code, and unused symbols.

**Deliverables:**

1. **Structural clone detection (Type-2):** normalized AST fingerprints over
   statement windows, cross-file within a root, minimum-size threshold, grouped
   matches, vendored/generated exclusions, medium confidence.
2. **Dead code and unused symbols:** unused private symbols (definition with no
   references in root, exports excluded), unused imports, and unused parameters
   (skipping overrides, interface implementations, and callbacks). Advisory only;
   never auto-removed.
3. **Quality corpus:** fixtures plus this repository plus representative external
   repos; per-rule false-positive notes; bench gate for the new analysis.

**Acceptance:**

- Seeded clones are detected in at least two languages without flagging
  reformatted-but-different code.
- Unused-symbol detection finds the seeded cases; false positives are documented.
- Performance stays within the bench gate; the report states each new rule's
  limitations.

### P2 — Language breadth

**Problem:** six languages is narrow relative to REA's substrate coverage.

**Deliverables:**

1. JavaScript grammar first (separate from TSX), making it the seventh supported
   language.
2. Then a user-prioritized list. Recommendation: Java, Kotlin, C/C++; Swift optional.
3. A rule-applicability matrix per language: which rules run, which are skipped, and
   why.

**Acceptance:**

- Each language passes shared fixtures or a documented subset.
- Coverage and limitations output stays accurate.
- The release build matrix is unchanged; grammars remain embedded.

### P2.5 — Persistence and history

**Problem:** `storage/db.zig` is an in-memory stub; the ledger cannot survive a
process exit; docs, spec, and the stale binary claim WAL storage that the current
build does not have.

**Deliverables:**

1. **Implement embedded storage** using the vendored SQLite amalgamation, as the
   engine spec requires: WAL mode, schema migrations, and a real backend version
   string. (A JSONL fallback is explicitly rejected; utility and documented behavior
   depend on the ACID ledger.)
2. **Schema:** refactor ledger and run history (timestamp, version, root, totals).
   The file-cache and symbol-index tables from the engine spec ship with the
   incremental phase instead, so P2.5 creates no unused tables.
3. **Surfaces:** `zero-noise status` (backend, indexed files, last run) and
   `zero-noise log` (ledger entries and outcomes); `repo_report` includes a history
   summary.
4. **Artifact truth:** remove the hardcoded `(no-sqlite)` string, refresh or delete
   the stale tracked `bin/zero-noise`, and align README, CHANGELOG, and the engine
   spec with the actual build.

**Acceptance:**

- Ledger and run history survive process exits; `log` shows entries from prior runs.
- Concurrent invocations do not corrupt state.
- Docs and version output match the build; `zig build test` is green.

## 7. Cross-cutting requirements

- **Metadata and docs sync:** `manifest.json` grows a machine-readable surface list
  (`cli_commands`, `mcp_tools`) that `sync_manifests.py --check` verifies against
  `src/mcp/protocol.zig` and the `AGENTS.md` tables; every new command, tool, or flag
  lands with README and CHANGELOG updates in the same change.
- **Skill and harness parity:** the skill, slash command, and agent prompt describe new
  flows (plans, patches, baselines) and remain accurate on all four harnesses.
- **Tests:** fixtures per rule and language; determinism tests; leak-free runs.
- **Bench gate:** new analysis modules add bench cases and respect the existing
  performance envelope.
- **Formats:** preserve text/json/sarif/compact contracts; version new report schemas.
- **Safety invariants:** hash lock, syntax validation, atomic rollback, workspace
  confinement, the guard/predicate test requirement, no behavior changes.

## 8. My calls (not user decisions)

Resolved while writing this document and during its review; each is reversible and
open to objection.

- **P0 composition:** multiple proposals per file merge into one candidate when their
  edits do not overlap; overlaps are flagged; any apply invalidates sibling proposals
  via the file hash and forces a re-plan. Composition is a public surface
  (`propose_fixes(compose=true)`, `plan --compose`), not only an internal helper.
- **P0 rule coverage:** guards (nesting), constants (repeated literals), predicates
  (raw booleans), and closure extraction (long closures) become machine-applicable;
  closure extraction ships last within P0. Commented-out code stays advisory.
- **Extraction placement:** same file only; nearest common scope; private, never
  exported; collision-checked names; downgrade to advisory when naming or typing is
  unsafe to synthesize.
- **Guard safety bar:** a closed per-language syntactic allowlist plus the test
  bracket. The allowlist includes tail position: no executable statements may follow
  the guarded `if` up the block chain to the function body, and the chain must contain
  no loop, switch, or handler block. `safe_to_apply` is false unless the allowlist is
  proven; `confidence` only ranks priority. `test_cmd` is mandatory — enforced by the
  engine — for applying guard or predicate patches; boolean, constant, and closure
  transforms keep it optional with mandatory hash lock and syntax validation.
- **Baseline identity:** per-file, per-rule counts in schema v1; fingerprints deferred.
  New parse errors on previously parsing files count as regressions; deletions are
  ignored; renames are new-plus-removed; config and version drift warn, with strict
  modes opt-in.
- **Baseline defaults:** new files are exempt; per-file regressions gate; aggregate
  deltas are informational.
- **Report normalization:** root-relative `/`-separated sorted paths; identity hash
  over LF-normalized content; the state lock keeps raw-byte hashes.
- **Limitations rollout:** mandatory on new surfaces; additive retrofit of existing
  tools lands by P1 end without signature changes.
- **Inventory:** current walker defaults preserved; new include/exclude keys in
  `.zero-noise.json`; symlinks not followed; root auto-discovery with `--config`
  override.
- **Persistence scope:** P2.5 ships ledger, run history, `status`, and `log` first;
  the file-cache and symbol-index tables and their use as an analysis cache are
  deferred to a later phase. P0.5 stays persistence-independent.
- **Patch format:** the internal unified-diff-like format is guaranteed
  zero-noise-applicable; `git apply` interoperability is deferred.
- **MCP surface:** exactly two new tools (`propose_fixes`, `repo_report`); baselines
  stay CLI-only; `evaluate_rules` is frozen.
- **Docs truth:** Zig is documented as the sixth supported language; the stale tracked
  `bin/zero-noise` is replaced by release artifacts in P2.5.
- **Harness parity:** every new surface lands on all four harnesses.
- **`safe_refactor`:** dry-run defaults everywhere; apply requires explicit opt-in;
  the additive `patch_content` parameter is P0 work.

## 9. Deferred decisions

- **Language order after JavaScript** (P2): decided at phase kickoff from actual
  usage; JavaScript ships first.
- **Incremental analysis index** (post-P2.5): whether analyses read the symbol and
  file index as a cache, or rebuild per run.

## 10. References

- `docs/specs/2026-10-16-zig-engine-reconstruction-design.md` — engine architecture.
- `COLLABORATION.md` — invariants and contribution rules.
- `src/mutation/rewriter.zig`, `src/mutation/runner.zig` — current rewrite and apply
  pipeline.
- `src/analysis/noise.zig` — current rule set and finding model.
- `src/storage/db.zig`, `src/storage/ledger.zig` — persistence stub and ledger.
- `src/mcp/protocol.zig` — MCP tool contracts.
- `skills/zero-noise-refactor/`, `agents/`, `commands/` — agent-facing flows.
