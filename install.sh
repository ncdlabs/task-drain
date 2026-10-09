#!/usr/bin/env bash
# install.sh -- symlink task-drain scripts into ~/bin (or $PREFIX/bin)
#
# Usage:
#   ./install.sh                  # symlinks into ~/bin
#   PREFIX=/usr/local ./install.sh  # symlinks into /usr/local/bin
#
# This symlinks (not copies) so `git pull` in the repo updates your install.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME}"
BINDIR="$PREFIX/bin"

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

echo ""
echo "Done. Make sure $BINDIR is on your PATH."
echo "Then: drain docs   # read the pickup rules before starting workers"
