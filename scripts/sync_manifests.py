#!/usr/bin/env python3
"""
DRY manifest synchronizer.
Reads manifest.json (single source of truth) and projects metadata to:
- plugin.json
- mcp_config.json
- gemini-extension.json
- .claude-plugin/plugin.json
- .mcp.json

In --check mode it also verifies the surface lists declared in manifest.json:
- mcp_tools against the name fields of the TOOLS array in src/mcp/protocol.zig;
- cli_commands against the Commands section of the usage text in src/main.zig.

Every command in the usage Commands section is verified except:
- help and version: meta aliases for --help/--version, not domain commands;
- bootstrap: one-time environment/state provisioning, also accepted as the
  --bootstrap flag, and not part of the analysis/refactor surface this list
  tracks. It is absent from README and AGENTS.md, unlike the five verified
  commands: mcp (the server entry point used by the generated descriptors),
  audit, complexity, blast, and refactor.
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_FILE = REPO_ROOT / "manifest.json"
PLUGIN_NAME = "zero-noise"

SURFACE_SOURCES = {
    "cli_commands": REPO_ROOT / "src" / "main.zig",
    "mcp_tools": REPO_ROOT / "src" / "mcp" / "protocol.zig",
}
EXCLUDED_CLI_COMMANDS = frozenset({"help", "version", "bootstrap"})


def parse_cli_commands(source: str) -> list[str]:
    """Extracts command names from the Commands block of main.zig's usage text."""
    usage_lines: list[str] = []
    for line in source.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("\\\\"):
            usage_lines.append(stripped[2:])

    commands: list[str] = []
    in_commands = False
    for line in usage_lines:
        text = line.strip()
        if text == "Commands:":
            in_commands = True
            continue
        if not in_commands or not text:
            continue
        if text == "Options:":
            break
        match = re.match(r"^\s{2}([a-z][a-z0-9-]*)\b", line)
        if match and match.group(1) not in EXCLUDED_CLI_COMMANDS:
            commands.append(match.group(1))
    return commands


def parse_mcp_tools(source: str) -> list[str]:
    """Extracts tool names from the TOOLS array in protocol.zig."""
    tools_block = re.search(
        r"pub const TOOLS\s*=\s*\[_\]ToolDefinition\s*\{(.*?)\n\};",
        source,
        re.DOTALL,
    )
    if tools_block is None:
        return []
    return re.findall(r'\.name\s*=\s*"([^"]+)"', tools_block.group(1))


def _manifest_surface(meta: dict, key: str) -> tuple[list[str] | None, str | None]:
    if key not in meta:
        return None, f"manifest.json is missing '{key}'"
    value = meta[key]
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        return None, f"manifest.json '{key}' must be a list of strings"
    return value, None


def _surface_diff(label: str, declared: list[str], actual: list[str]) -> list[str]:
    declared_set = set(declared)
    actual_set = set(actual)

    missing = list(dict.fromkeys(name for name in actual if name not in declared_set))
    extra = list(dict.fromkeys(name for name in declared if name not in actual_set))
    duplicates = sorted({name for name in declared if declared.count(name) > 1})

    problems: list[str] = []
    if missing:
        problems.append(f"{label}: present in source but missing from manifest.json: {', '.join(missing)}")
    if extra:
        problems.append(f"{label}: present in manifest.json but missing from source: {', '.join(extra)}")
    if duplicates:
        problems.append(f"{label}: duplicate entries in manifest.json: {', '.join(duplicates)}")
    return problems


def verify_surfaces(meta: dict, quiet: bool = False) -> int:
    """Compares manifest surface lists with the current CLI and MCP sources."""
    checks = (
        ("cli_commands", "Commands section of src/main.zig", parse_cli_commands),
        ("mcp_tools", "TOOLS array in src/mcp/protocol.zig", parse_mcp_tools),
    )
    problems: list[str] = []
    counts: list[str] = []

    for key, source_label, parser in checks:
        declared, error = _manifest_surface(meta, key)
        if error is not None:
            problems.append(error)
            continue

        source_path = SURFACE_SOURCES[key]
        relative_path = source_path.relative_to(REPO_ROOT)
        if not source_path.is_file():
            problems.append(f"{key}: source file not found: {relative_path}")
            continue

        actual = parser(source_path.read_text(encoding="utf-8"))
        if not actual:
            problems.append(f"{key}: no entries parsed from the {source_label}")
            continue

        problems.extend(_surface_diff(key, declared, actual))
        counts.append(f"{len(actual)} {key.replace('_', ' ')}")

    if problems:
        print(f"{PLUGIN_NAME}: error: surface lists out of sync with manifest.json:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "Update manifest.json so 'cli_commands' and 'mcp_tools' match "
            "src/main.zig and src/mcp/protocol.zig.",
            file=sys.stderr,
        )
        return 1

    if not quiet:
        print(f"{PLUGIN_NAME}: surfaces verified ({', '.join(counts)})")
    return 0


def generate_targets(meta: dict) -> dict[Path, str]:
    """Generates expected content map for all managed files."""
    mcp_config = {
        "command": PLUGIN_NAME,
        "args": ["mcp"],
    }

    # 1. plugin.json (Antigravity agy root descriptor)
    plugin_json = {
        "name": meta["name"],
        "version": meta["version"],
        "description": meta["description"],
        "author": meta.get("author", {}),
        "license": meta.get("license", "MIT"),
        "keywords": meta.get("keywords", []),
    }

    # 2. mcp_config.json (Antigravity agy plugin MCP server descriptor)
    agy_mcp_json = {
        "mcpServers": {
            PLUGIN_NAME: mcp_config,
        },
    }

    # 3. gemini-extension.json (Gemini CLI extension descriptor)
    gemini_json = {
        "name": meta["name"],
        "description": meta["description"],
        "version": meta["version"],
        "contextFileName": meta.get("contextFileName", "AGENTS.md"),
        "mcpServers": {
            PLUGIN_NAME: mcp_config,
        },
    }

    # 4. .claude-plugin/plugin.json (Claude Code descriptor)
    claude_mcp_config = {
        "command": f"${{CLAUDE_PLUGIN_ROOT}}/bin/{PLUGIN_NAME}",
        "args": ["mcp"],
    }
    claude_json = {
        "name": meta["name"],
        "description": meta["description"],
        "version": meta["version"],
        "author": meta.get("author", {}),
        "homepage": meta.get("homepage", ""),
        "repository": meta.get("repository", ""),
        "license": meta.get("license", "MIT"),
        "keywords": meta.get("keywords", []),
        "mcpServers": {
            PLUGIN_NAME: claude_mcp_config,
        },
    }

    # 5. .mcp.json (Root Claude Code / Universal MCP server descriptor)
    root_mcp_json = {
        "mcpServers": {
            PLUGIN_NAME: mcp_config,
        },
    }

    targets = {
        REPO_ROOT / "plugin.json": json.dumps(plugin_json, indent=2) + "\n",
        REPO_ROOT / "mcp_config.json": json.dumps(agy_mcp_json, indent=2) + "\n",
        REPO_ROOT / "gemini-extension.json": json.dumps(gemini_json, indent=2) + "\n",
        REPO_ROOT / ".claude-plugin" / "plugin.json": json.dumps(claude_json, indent=2) + "\n",
        REPO_ROOT / ".mcp.json": json.dumps(root_mcp_json, indent=2) + "\n",
    }
    return targets


def check_manifests(targets: dict[Path, str], quiet: bool = False) -> int:
    out_of_sync = []
    for file_path, expected_content in targets.items():
        if not file_path.is_file():
            out_of_sync.append(str(file_path.relative_to(REPO_ROOT)))
            continue
        if file_path.read_text(encoding="utf-8") != expected_content:
            out_of_sync.append(str(file_path.relative_to(REPO_ROOT)))

    if not out_of_sync:
        if not quiet:
            print(f"{PLUGIN_NAME}: all manifests are in sync with manifest.json")
        return 0

    print(f"{PLUGIN_NAME}: error: manifests out of sync with manifest.json:", file=sys.stderr)
    for item in out_of_sync:
        print(f"  - {item}", file=sys.stderr)
    print("Run 'python3 scripts/sync_manifests.py' to update.", file=sys.stderr)
    return 1


def sync_manifests(check: bool = False, quiet: bool = False) -> int:
    if not MANIFEST_FILE.is_file():
        raise FileNotFoundError(f"File not found: {MANIFEST_FILE}")

    with open(MANIFEST_FILE, "r", encoding="utf-8") as f:
        meta = json.load(f)

    targets = generate_targets(meta)
    if check:
        manifests_code = check_manifests(targets, quiet=quiet)
        surfaces_code = verify_surfaces(meta, quiet=quiet)
        return max(manifests_code, surfaces_code)

    for file_path, content in targets.items():
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(content, encoding="utf-8")

    if not quiet:
        synced_names = ", ".join(str(p.relative_to(REPO_ROOT)) for p in targets.keys())
        print(f"{PLUGIN_NAME}: synchronized manifests to {synced_names}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Synchronize manifests across extensions and plugins.")
    parser.add_argument("--check", action="store_true", help="Check whether manifests are in sync without writing.")
    parser.add_argument("-q", "--quiet", action="store_true", help="Suppress output (silence)")
    args = parser.parse_args()
    code = sync_manifests(check=args.check, quiet=args.quiet)
    sys.exit(code)


if __name__ == "__main__":
    main()
