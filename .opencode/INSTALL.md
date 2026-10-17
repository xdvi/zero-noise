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

### OpenCode Action and Tool Mapping

| Skill Action             | Native OpenCode Tool                 |
|--------------------------|--------------------------------------|
| Static structural audit  | `bash` (`zero-noise audit <path>`)   |
| Read reference guidelines| `read`                               |
| Refactor edits           | `apply_patch` / `edit`               |
| Final verification       | `bash` (`zero-noise audit <path>`)   |

## 4. Triggers

Invoke the refactorer directly in conversation:
- *"Apply zero-noise-refactor to this file"*
- *"Refactor this handler to remove nesting and noise"*
- *"Clean up inline lambdas and apply early return"*
- Or via the explicit slash command: `/zero-noise [path]`
