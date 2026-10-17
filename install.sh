#!/bin/sh
set -eu

REPO="xdvi/zero-noise"
VERSION="${ZERO_NOISE_VERSION:-latest}"
INSTALL_DIR="${ZERO_NOISE_INSTALL_DIR:-$HOME/.local/bin}"
CONFIG_PLUGINS=false
FROM_SOURCE=false

show_help() {
    cat << EOF
zero-noise universal installer

Usage:
  ./install.sh [options]

Options:
  --dir <path>       Install destination directory (default: ~/.local/bin)
  --version <ver>    Version or git tag to install (default: latest)
  --build            Build and install from local source using Zig
  --plugins          Configure plugins for Antigravity, Claude, OpenCode, and Codex
  --codex            Configure plugin for Codex
  -h, --help         Show this help message

Environment variables:
  ZERO_NOISE_INSTALL_DIR   Override installation directory
  ZERO_NOISE_VERSION       Override version tag
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)
            if [ -n "${2:-}" ]; then
                INSTALL_DIR="$2"
                shift 2
            else
                echo "Error: --dir requires a path" >&2
                exit 1
            fi
            ;;
        --version)
            if [ -n "${2:-}" ]; then
                VERSION="$2"
                shift 2
            else
                echo "Error: --version requires a version tag" >&2
                exit 1
            fi
            ;;
        --build)
            FROM_SOURCE=true
            shift
            ;;
        --plugins|--all|--agy|--claude|--opencode|--codex)
            CONFIG_PLUGINS=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

detect_os() {
    os_name="$(uname -s)"
    case "$os_name" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        CYGWIN*|MINGW*|MSYS*|Windows_NT*) echo "windows" ;;
        *)
            echo "unsupported"
            ;;
    esac
}

detect_arch() {
    arch_name="$(uname -m)"
    case "$arch_name" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *)
            echo "unsupported"
            ;;
    esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

if [ "$OS" = "unsupported" ] || [ "$ARCH" = "unsupported" ]; then
    echo "Error: Unsupported operating system ($OS) or architecture ($ARCH)." >&2
    exit 1
fi

case "${ARCH}-${OS}" in
    x86_64-linux)   TARGET="x86_64-linux-musl" ; EXT="tar.gz" ;;
    aarch64-linux)  TARGET="aarch64-linux-musl" ; EXT="tar.gz" ;;
    aarch64-macos)  TARGET="aarch64-macos" ; EXT="tar.gz" ;;
    x86_64-macos)   TARGET="x86_64-macos" ; EXT="tar.gz" ;;
    x86_64-windows) TARGET="x86_64-windows-gnu" ; EXT="zip" ;;
    *)
        echo "Error: No pre-compiled binary available for ${ARCH}-${OS}." >&2
        exit 1
        ;;
esac

echo "==> Detected target: $TARGET"

mkdir -p "$INSTALL_DIR"

install_local_build() {
    echo "==> Building zero-noise from source with zig..."
    zig build -Doptimize=ReleaseFast
    if [ "$OS" = "windows" ]; then
        if [ -f "zig-out/bin/zero-noise.exe" ]; then
            cp -f "zig-out/bin/zero-noise.exe" "$INSTALL_DIR/zero-noise.exe"
            echo "✔ Installed $INSTALL_DIR/zero-noise.exe"
            return 0
        fi
    else
        if [ -f "zig-out/bin/zero-noise" ]; then
            cp -f "zig-out/bin/zero-noise" "$INSTALL_DIR/zero-noise"
            chmod +x "$INSTALL_DIR/zero-noise"
            echo "✔ Installed $INSTALL_DIR/zero-noise"
            return 0
        fi
    fi
    echo "Error: Build succeeded but binary not found in zig-out/bin/" >&2
    exit 1
}

download_file() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo "Error: curl or wget is required to download binaries." >&2
        exit 1
    fi
}

install_binary() {
    if [ "$FROM_SOURCE" = "true" ]; then
        if command -v zig >/dev/null 2>&1; then
            install_local_build
            return 0
        fi
        echo "Error: --build specified but zig compiler not found in PATH." >&2
        exit 1
    fi

    if [ "$VERSION" = "latest" ]; then
        URL="https://github.com/${REPO}/releases/latest/download/zero-noise-${TARGET}.${EXT}"
    else
        URL="https://github.com/${REPO}/releases/download/${VERSION}/zero-noise-${TARGET}.${EXT}"
    fi

    TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'zero-noise')"
    ARCHIVE="$TMP_DIR/zero-noise.${EXT}"

    echo "==> Downloading zero-noise from $URL..."
    if ! download_file "$URL" "$ARCHIVE"; then
        echo "Warning: Download failed. Trying fallback to source build if zig is available..." >&2
        if command -v zig >/dev/null 2>&1 && [ -f "build.zig" ]; then
            install_local_build
            rm -rf "$TMP_DIR"
            return 0
        fi
        echo "Error: Could not download pre-built binary for $TARGET." >&2
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "==> Extracting binary..."
    if [ "$EXT" = "zip" ]; then
        unzip -q -o "$ARCHIVE" -d "$TMP_DIR"
        mv -f "$TMP_DIR/zero-noise.exe" "$INSTALL_DIR/zero-noise.exe"
    else
        tar -xzf "$ARCHIVE" -C "$TMP_DIR"
        mv -f "$TMP_DIR/zero-noise" "$INSTALL_DIR/zero-noise"
        chmod +x "$INSTALL_DIR/zero-noise"
    fi

    rm -rf "$TMP_DIR"
    echo "✔ Installed zero-noise to $INSTALL_DIR"
}

configure_plugins() {
    ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "==> Configuring editor and agent plugins..."

    # Antigravity (agy)
    AGY_DIR="$HOME/.gemini/config/plugins/zero-noise"
    mkdir -p "$(dirname "$AGY_DIR")"
    if [ -d "$ROOT_DIR" ]; then
        ln -sfn "$ROOT_DIR" "$AGY_DIR"
        echo "✔ Linked Antigravity plugin: $AGY_DIR"
    fi

    # OpenCode
    OPENCODE_DIR="$HOME/.config/opencode"
    if [ -d "$OPENCODE_DIR" ]; then
        mkdir -p "$OPENCODE_DIR/skills" "$OPENCODE_DIR/commands" "$OPENCODE_DIR/agents"
        ln -sfn "$ROOT_DIR/skills/zero-noise-refactor" "$OPENCODE_DIR/skills/zero-noise-refactor"
        ln -sfn "$ROOT_DIR/commands/zero-noise.md" "$OPENCODE_DIR/commands/zero-noise.md"
        ln -sfn "$ROOT_DIR/agents/zero-noise-refactor.md" "$OPENCODE_DIR/agents/zero-noise-refactor.md"
        echo "✔ Linked OpenCode skills, commands, and agent"
    fi

    # Codex
    CODEX_DIR="$HOME/.codex"
    if [ -d "$CODEX_DIR" ]; then
        mkdir -p "$CODEX_DIR/skills" "$CODEX_DIR/agents"
        ln -sfn "$ROOT_DIR/skills/zero-noise-refactor" "$CODEX_DIR/skills/zero-noise-refactor"
        ln -sfn "$ROOT_DIR/agents/zero-noise-refactor.md" "$CODEX_DIR/agents/zero-noise-refactor.md"
        echo "✔ Linked Codex skills and agent"
    fi
}

install_binary

if [ "$CONFIG_PLUGINS" = "true" ]; then
    configure_plugins
fi

echo ""
echo "=== Installation complete ==="
echo "Binary location: $INSTALL_DIR/zero-noise"
case ":$PATH:" in
    *:"$INSTALL_DIR":*) ;;
    *)
        echo "Note: $INSTALL_DIR is not currently in your PATH."
        echo "Add it to your profile (e.g. ~/.bashrc or ~/.zshrc):"
        echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
esac
