# zero-noise

> Structural silence. Clean code that means what it says.

A universal plugin for **Claude Code**, **Antigravity (agy)**, **OpenCode**, and **OpenAI Codex** (with support for **Kimi**, **Grok**, and any MCP-compliant agent) that enforces zero-noise refactoring: DRY, early return, semantic predicates, and algebraic simplification — across Go, Rust, TypeScript, Python, and C#.

---

## What it does

- **Audits** structural noise: deep nesting (>2 levels), anonymous closures in argument position, raw conditionals, duplicated literals, and commented-out dead code.
- **Auto-fixes** algebraic simplifications with `--fix` (De Morgan's laws, `endsWith` shortcuts, and boolean return cleanups).
- **Proposes** machine-applicable fixes via `plan` / `propose_fixes` — guard, predicate, constant, and closure rewrites, each locked to the source SHA-256 (`expected_hash`) and composable into a single patch.
- **Validates** that the noise score is strictly lower after the refactor with compiled native Zig engine with zero external runtime dependencies.

---

## Install

### Quick Install (Universal)

Clone and run the one-stop installer and updater:

```bash
git clone https://github.com/xdvi/zero-noise
cd zero-noise
./install.sh
```

Flags:
- `./install.sh` (or `./install.sh --all`): Configures Antigravity, Claude Code, OpenCode, and OpenAI Codex.
- `./install.sh --agy`: Configures Antigravity only.
- `./install.sh --claude`: Configures Claude Code only.
- `./install.sh --opencode`: Configures OpenCode only.
- `./install.sh --codex`: Configures OpenAI Codex only.

---

### Antigravity (agy)

**Install via CLI**:
```bash
agy plugin install <path-to-zero-noise>
```

Or clone directly into the Antigravity plugins directory:
```bash
git clone https://github.com/xdvi/zero-noise ~/.gemini/config/plugins/zero-noise
```

**Update**:
Re-run `agy plugin install <path-to-zero-noise>`, or `git pull` inside `~/.gemini/config/plugins/zero-noise`.

---

### Claude Code

**Install via marketplace**:
```bash
# From GitHub repository
claude plugin install zero-noise --marketplace xdvi/zero-noise

# Or from local clone
claude plugin install zero-noise --marketplace ./
```

**Update**:
```bash
claude plugin update zero-noise
```

---

### OpenCode

Auto-discovered via `.opencode/agent/` and `.opencode/command/`. See [`.opencode/INSTALL.md`](.opencode/INSTALL.md) for detailed setup.

**Install via `opencode.json`**:
Add `zero-noise` to the `plugins` array (globally in `~/.config/opencode/opencode.json` or project-level `opencode.json`):

```json
{
  "plugins": [
    "zero-noise@git+https://github.com/xdvi/zero-noise.git"
  ]
}
```

Or from a local clone:

```json
{
  "plugins": [
    "<path-to-zero-noise>"
  ]
}
```

**Global MCP Configuration in `opencode.json`**:
Configure the zero-noise MCP server in `~/.config/opencode/opencode.json` (or project-level `opencode.json`):

```json
{
  "mcp": {
    "zero-noise": {
      "type": "local",
      "command": [
        "zero-noise",
        "mcp"
      ]
    }
  }
}
```

Or link automatically via `./install.sh --opencode`.

---

### OpenAI Codex

**Automatic setup**:
```bash
./install.sh --codex
```
This automatically links `skills/zero-noise-refactor` into `~/.codex/skills/` and registers the MCP server in `~/.codex/config.toml`.

**Manual configuration (`~/.codex/config.toml`)**:
Add the MCP server and marketplace to your Codex configuration:

```toml
[mcp_servers.zero-noise]
command = "zero-noise"
args = [
    "mcp",
]

[marketplaces.zero-noise]
source = "https://github.com/xdvi/zero-noise.git"
source_type = "git"

[plugins."zero-noise@zero-noise"]
enabled = true
```

---

### MCP (Model Context Protocol)

For Cursor, Windsurf, Claude Desktop, or custom agent harnesses:

```json
{
  "mcpServers": {
    "zero-noise": {
      "command": "zero-noise",
      "args": ["mcp"]
    }
  }
}
```

---

## Usage

Trigger via slash command:
```bash
/zero-noise src/modules/auth/service.go
```

Or ask your agent naturally:
- *"Refactor this handler, too much nesting"*
- *"Zero-noise refactor this file"*
- *"Clean up this hook, closures everywhere"*
- *"Apply early return and extract predicates here"*

The agent audits first, refactors, then re-validates. It never changes behavior — only structure.

---

## CLI Commands

The `zero-noise` standalone static binary provides high-speed native commands for code analysis and refactoring:

### `zero-noise audit`

Static linter detecting nesting, closures, complex booleans, and commented code blocks:

```bash
# Text output
zero-noise audit <path>

# Structured JSON output
zero-noise audit <path> --format=json

# Compact agent-optimized format
zero-noise audit <path> --format=compact
```

### `zero-noise complexity`

Calculates SonarSource Cognitive Complexity per function:

```bash
zero-noise complexity <path> --threshold=15
```

### `zero-noise blast`

Calculates definition sites, reference callers, and coupling blast radius:

```bash
zero-noise blast <symbol> --root=.
```

### `zero-noise refactor`

Guaranteed safe test-bracketed refactoring runner with automatic rollback on test failure. Dry-run is the default; applying requires explicit `--fix`:

```bash
# Dry run (default)
zero-noise refactor <file>

# Apply algebraic simplifications and verify with test suite
zero-noise refactor <file> --test-cmd="npm test" --fix

# Apply a patch from `plan` / `propose_fixes`
zero-noise refactor <file> --patch-file=fix.patch --patch-kind=guard --expected-hash=<sha256> --test-cmd="npm test" --fix
```

Apply contract:

- Applications supplying `candidate_content`, `patch_content`, or `patch_file` must declare an explicit `patch_kind` (`guard`, `predicate`, `constant`, `closure`, `boolean`, or `manual`); the engine aborts without one.
- The engine verifies the declared kind against its own proposals when the patch reproduces one (or a composition), aborting on `classification mismatch`; free-form patches keep the declared kind.
- `guard` and `predicate` patches require `test_cmd` — the engine refuses them otherwise.
- `expected_hash` is the SHA-256 captured at proposal time; any file change aborts with `state lock failed`.

### `zero-noise plan`

Lists machine-applicable fix proposals (guard, predicate, constant, closure) for a file or directory — the same report the `propose_fixes` MCP tool returns. Every proposal carries an `expected_hash` state lock; proposals never fail the command (exit `0` with findings, `1` on errors):

```bash
# Text output
zero-noise plan <path>

# Structured JSON output
zero-noise plan <path> --format=json

# Include the unified diff for each proposal
zero-noise plan <path> --include-patches

# Compose non-overlapping proposals into one applicable patch
zero-noise plan <path> --compose

# Write the composed patch to a file (summary line still printed)
zero-noise plan <path> --compose --out=fix.patch

# Restrict kinds, paginate, or scope the walk
zero-noise plan <path> --kinds=guard,constant --page=1 --page-size=10 --root=.
```

Composition is greedy and deterministic: non-overlapping proposals merge into one candidate, overlapping ones are reported as conflicts (`composed: applied=2 conflicts=1`). Proposals flagged `naming_required` carry placeholder names (e.g. `isUserReady`, `extractedClosure1`) — propose real domain names to the user before applying.

### Git Pre-Commit Hook

Protect your repository by installing the pre-commit hook:

```bash
ln -sf ../../scripts/pre-commit .git/hooks/pre-commit
```

---

## Configuration (`.zero-noise.json` & `.zero-noise-rules.json`)

Optional configuration files placed in the repository root:

```json
{
  "max_nesting": 2,
  "max_closure_len": 80,
  "ignore_patterns": [
    "node_modules",
    "vendor",
    ".git",
    "__pycache__",
    "dist",
    "build"
  ]
}
```

Declarative custom rules example (`.zero-noise-rules.json`):
```json
[
  {
    "id": "no-direct-fetch",
    "pattern": "fetch\\(",
    "severity": "warning",
    "message": "Use configured apiClient instead of raw fetch()",
    "languages": [".ts", ".js"]
  }
]
```

---

## Structure

```
zero-noise/
├── .github/
│   └── workflows/
│       └── ci.yml                   # GitHub Actions multi-version matrix (Python 3.10-3.13)
├── manifest.json                    # Single source of truth (DRY)
├── plugin.json                      # Antigravity root manifest (generated)
├── gemini-extension.json            # Gemini / agy metadata (generated)
├── .claude-plugin/
│   └── plugin.json                  # Claude Code manifest (generated)
├── .opencode/
│   ├── agent/
│   │   └── zero-noise-refactor.md   # Symlink -> ../../agents/zero-noise-refactor.md
│   ├── command/
│   │   └── zero-noise.md            # Symlink -> ../../commands/zero-noise.md
│   └── INSTALL.md                   # Quick guide and hooks for OpenCode
├── AGENTS.md                        # Universal context (OpenCode, agy, Kimi, Grok)
├── README.md                        # Documentation and install guide
├── install.sh                       # Universal installer and updater (agy, Claude, OpenCode)
├── LICENSE                          # MIT
├── commands/
│   └── zero-noise.md                # Explicit slash command (/zero-noise)
├── agents/
│   └── zero-noise-refactor.md       # Canonical autonomous subagent
├── src/
│   ├── main.zig                     # CLI entrypoint & router
│   ├── root.zig                     # Library root module
│   ├── analysis/                    # Cognitive complexity, noise, and blast radius
│   ├── mutation/                    # Algebraic rewriter and transactional runner
│   ├── storage/                     # In-memory state database and state-lock ledger
│   ├── treesitter/                  # Tree-sitter C ABI bindings and grammars
│   ├── mcp/                         # JSON-RPC 2.0 stdio server & protocol
│   └── cli/                         # Subcommand handlers
├── c/                               # Embedded SQLite3 & Tree-sitter C ABI grammars
├── skills/
│   └── zero-noise-refactor/
│       ├── SKILL.md                 # Agent skill descriptor
│       └── reference/
│           ├── cleanliness_rules.md
│           └── architecture_patterns.md
├── scripts/
│   ├── sync_manifests.py            # Manifest synchronizer from manifest.json
│   └── pre-commit                   # Pre-commit git hook
├── install.sh                       # Universal POSIX installer
└── tests/
    └── fixtures/                    # Multi-language AST fixtures (Go, Rust, TS, Py, C#)
        ├── dirty/
        ├── clean/
        └── fix/
```

---

## Testing & Verification

Run the native test suite:

```bash
zig build test
```

---

## License

MIT
