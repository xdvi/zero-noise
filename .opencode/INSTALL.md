# OpenCode Installation and Configuration

## 1. Quick Installation

Add `zero-noise` to the `plugins` array in your `opencode.json` (globally in `~/.config/opencode/opencode.json` or project-level):

```json
{
  "plugins": [
    "zero-noise@git+https://github.com/xdvi/zero-noise.git"
  ]
}
```

Or when running from a local checkout:

```json
{
  "plugins": [
    "/home/dabi/Proyectos/zero-noise"
  ]
}
```

## 2. MCP Server Configuration

Register the MCP server in `~/.config/opencode/opencode.json` (or project-level `opencode.json`) under `mcp.servers`:

```json
{
  "mcp": {
    "servers": {
      "zero-noise": {
        "command": ["zero-noise", "mcp"],
        "type": "local"
      }
    }
  }
}
```

## 3. Agent, Command, and Skill Discovery

While `.opencode/` is automatically discovered in the project workspace (via canonical symlinks), global discovery across projects requires adding the skill to `~/.config/opencode/skills` or registering in `opencode.json`.

Project workspace discovery links:
- Subagent: `.opencode/agent/zero-noise-refactor.md` -> `../../agents/zero-noise-refactor.md`
- Command: `.opencode/command/zero-noise.md` -> `../../commands/zero-noise.md`

### OpenCode MCP & CLI Tool Mapping

| MCP Tool (`zero-noise`) | CLI Fallback | Purpose |
|-------------------------|--------------|---------|
| `inspect_evidence` | `zero-noise audit <path> --format=compact` | Prioritized, state-locked Evidence Contract pack |
| `audit_noise` | `zero-noise audit <path>` | Structural noise linter (nesting > 2, closures > 80 chars, raw booleans, commented code) |
| `refactor_helper` | `zero-noise refactor <file> --dry-run` | DRY repeated literals and boolean algebraic simplification preview |
| `complexity` | `zero-noise complexity <path> --threshold=15` | SonarSource Cognitive Complexity per function |
| `blast_radius` | `zero-noise blast <symbol> --root=.` | Symbol usages, definitions, and cross-file coupling risk |
| `safe_refactor` | `zero-noise refactor <file> --expected-hash="<sha256>" --test-cmd="<cmd>" --fix` | Test-bracketed refactoring runner with state-lock hash and atomic rollback |
| `evaluate_rules` | `zero-noise audit <path>` | Declarative AST and regex anti-pattern rules from `.zero-noise-rules.json` |

## 4. Triggers

Invoke the refactorer directly in conversation:
- *"Apply zero-noise-refactor to this file"*
- *"Refactor this handler to remove nesting and noise"*
- *"Clean up inline lambdas and apply early return"*
- Or via the explicit slash command: `/zero-noise [path]`
