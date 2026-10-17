#!/usr/bin/env python3
"""
DRY manifest synchronizer.
Reads manifest.json (single source of truth) and projects metadata to:
- .claude-plugin/plugin.json
- gemini-extension.json
- plugin.json
"""

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_FILE = REPO_ROOT / "manifest.json"


def generate_targets(meta: dict) -> dict[Path, str]:
    """Generates expected content map for all managed files."""
    mcp_config = {
        "command": "zero-noise",
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
            "zero-noise": mcp_config,
        },
    }

    # 3. gemini-extension.json (Gemini CLI extension descriptor)
    gemini_json = {
        "name": meta["name"],
        "description": meta["description"],
        "version": meta["version"],
        "contextFileName": meta.get("contextFileName", "AGENTS.md"),
        "mcpServers": {
            "zero-noise": mcp_config,
        },
    }

    # 4. .claude-plugin/plugin.json (Claude Code descriptor)
    claude_mcp_config = {
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/zero-noise",
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
            "zero-noise": claude_mcp_config,
        },
    }

    # 5. .mcp.json (Root Claude Code / Universal MCP server descriptor)
    root_mcp_json = {
        "mcpServers": {
            "zero-noise": mcp_config,
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
        if not file_path.is_file() or file_path.read_text(encoding="utf-8") != expected_content:
            out_of_sync.append(str(file_path.relative_to(REPO_ROOT)))

    if not out_of_sync:
        if not quiet:
            print("zero-noise: all manifests are in sync with manifest.json")
        return 0

    print("zero-noise: error: manifests out of sync with manifest.json:", file=sys.stderr)
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
        return check_manifests(targets, quiet=quiet)

    for file_path, content in targets.items():
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(content, encoding="utf-8")

    if not quiet:
        synced_names = ", ".join(str(p.relative_to(REPO_ROOT)) for p in targets.keys())
        print(f"zero-noise: synchronized manifests to {synced_names}")
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
