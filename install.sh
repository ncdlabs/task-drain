#!/usr/bin/env bash
# install.sh -- set up task-drain and the opencode-tasks plugin
#
# Usage:
#   ./install.sh                  # symlinks into ~/bin, clones plugin to ~/git/opencode-tasks
#   PREFIX=/usr/local ./install.sh
#   SKIP_PLUGIN=1 ./install.sh    # skip the opencode-tasks plugin setup
#
# This symlinks (not copies) so `git pull` in the repos updates your install.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME}"
BINDIR="$PREFIX/bin"
SKIP_PLUGIN="${SKIP_PLUGIN:-0}"

# --- task-drain scripts ---
mkdir -p "$BINDIR"

for script in task-drain.sh drain; do
    src="$REPO_DIR/$script"
    dst="$BINDIR/$script"
    if [ ! -f "$src" ]; then
        echo "error: $src not found" >&2
        exit 1
    fi
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "backing up existing $dst to $dst.bak"
        mv "$dst" "$dst.bak"
    fi
    ln -sf "$src" "$dst"
    chmod +x "$src"
    echo "symlinked $dst -> $src"
done

mkdir -p "$HOME/.task-drain/logs"

# --- opencode-tasks plugin (optional but recommended) ---
if [ "$SKIP_PLUGIN" != "1" ]; then
    PLUGIN_DIR="${PLUGIN_DIR:-$HOME/git/opencode-tasks}"
    if [ -d "$PLUGIN_DIR/.git" ]; then
        echo ""
        echo "opencode-tasks already cloned at $PLUGIN_DIR, pulling latest..."
        git -C "$PLUGIN_DIR" pull --ff-only 2>/dev/null || echo "(pull failed, continuing)"
    elif [ -e "$PLUGIN_DIR" ]; then
        echo ""
        echo "warning: $PLUGIN_DIR exists but is not a git repo, skipping plugin install"
    else
        echo ""
        echo "cloning opencode-tasks plugin to $PLUGIN_DIR..."
        git clone https://github.com/ncdlabs/opencode-tasks.git "$PLUGIN_DIR"
    fi

    if [ -d "$PLUGIN_DIR" ]; then
        echo "building plugin..."
        (cd "$PLUGIN_DIR" && npm install --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -1)
        echo ""
        echo "To enable the plugin, add this to your opencode.json:"
        echo ""
        echo "  \"plugin\": ["
        echo "    \"$PLUGIN_DIR\""
        echo "  ],"
    fi
fi

echo ""
echo "Done. Make sure $BINDIR is on your PATH."
echo "Then: drain docs   # read the pickup rules before starting workers"
