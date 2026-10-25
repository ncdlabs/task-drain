#!/usr/bin/env bash
# install.sh -- full setup for task-drain: dependencies, sync server, scripts, plugin
#
# Usage:
#   ./install.sh                          # everything: deps, local sync server, symlinks, plugin
#   PREFIX=/usr/local ./install.sh        # install scripts to /usr/local/bin
#   SKIP_PLUGIN=1 ./install.sh            # skip the plugin build
#   SKIP_DEPS=1 ./install.sh              # skip dependency installation (task, jq)
#   TASKCHAMPION_URL=https://... ./install.sh   # use a remote sync server, skip local setup
#   TASKCHAMPION_LOCAL=0 ./install.sh     # skip local sync server setup entirely
#   PLUGIN_DIR=/path ./install.sh         # override plugin location
#
# Idempotent: safe to re-run. Already-installed components are detected and skipped.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME}"
BINDIR="$PREFIX/bin"
SKIP_PLUGIN="${SKIP_PLUGIN:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"
TASKCHAMPION_LOCAL="${TASKCHAMPION_LOCAL:-1}"

# Container runtime: auto-detect or override with CONTAINER_RUNTIME
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
if [ -z "$CONTAINER_RUNTIME" ]; then
	for candidate in nerdctl docker podman; do
		if command -v "$candidate" >/dev/null 2>&1; then
			CONTAINER_RUNTIME="$candidate"
			break
		fi
	done
fi

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" >&2; }
fail() {
	printf '\033[1;31m  fail\033[0m %s\n' "$*" >&2
	exit 1
}

# ---------------------------------------------------------------- OS detection
OS="$(uname -s)"
case "$OS" in
Darwin) OS_FAMILY="macos" ;;
Linux)
	if grep -qi microsoft /proc/version 2>/dev/null; then
		OS_FAMILY="wsl"
	else
		OS_FAMILY="linux"
	fi
	;;
MINGW* | MSYS* | CYGWIN*) OS_FAMILY="windows" ;;
*) OS_FAMILY="unknown" ;;
esac
info "Detected OS: $OS_FAMILY ($OS)"

if [ "$OS_FAMILY" = "windows" ]; then
	warn "Native Windows (Git Bash) is not supported for running workers."
	warn "Please use WSL2 (https://learn.microsoft.com/en-us/windows/wsl/) and"
	warn "re-run this installer inside your WSL distribution."
	exit 1
fi
if [ "$OS_FAMILY" = "unknown" ]; then
	warn "Unknown OS '$OS' — dependency installation will be skipped."
	warn "Install taskwarrior 3.x, jq, and an agent CLI manually, then re-run"
	warn "with SKIP_DEPS=1."
	SKIP_DEPS=1
fi

# Sudo helper: use sudo only when not root and sudo exists.
maybe_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		"$@"
	fi
}

# ---------------------------------------------------------------- dependencies
if [ "$SKIP_DEPS" != "1" ]; then
	info "Checking dependencies..."

	# --- Taskwarrior 3.x ---
	task_ok=0
	if command -v task >/dev/null 2>&1; then
		task_ver="$(task --version 2>/dev/null | head -1 || echo "0")"
		task_major="${task_ver%%.*}"
		if [ "$task_major" -ge 3 ] 2>/dev/null; then
			ok "taskwarrior $task_ver already installed"
			task_ok=1
		else
			warn "taskwarrior $task_ver found, but 3.x is required (TaskChampion sync)"
		fi
	fi
	if [ "$task_ok" -ne 1 ]; then
		info "Installing taskwarrior..."
		case "$OS_FAMILY" in
		macos)
			command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install it from https://brew.sh then re-run."
			brew install task
			;;
		linux | wsl)
			if command -v apt-get >/dev/null 2>&1; then
				maybe_sudo apt-get update -qq
				maybe_sudo apt-get install -y -qq taskwarrior
			elif command -v dnf >/dev/null 2>&1; then
				maybe_sudo dnf install -y -q task
			elif command -v pacman >/dev/null 2>&1; then
				maybe_sudo pacman -S --noconfirm task
			else
				fail "No supported package manager (apt-get/dnf/pacman). Install taskwarrior 3.x manually, then re-run with SKIP_DEPS=1."
			fi
			;;
		esac
		task_ver="$(task --version 2>/dev/null | head -1 || echo "unknown")"
		task_major="${task_ver%%.*}"
		[ "$task_major" -ge 3 ] 2>/dev/null || fail "taskwarrior installed but version is $task_ver — 3.x required for TaskChampion sync."
		ok "taskwarrior $task_ver installed"
	fi

	# --- jq ---
	if command -v jq >/dev/null 2>&1; then
		ok "jq already installed"
	else
		info "Installing jq..."
		case "$OS_FAMILY" in
		macos) brew install jq ;;
		linux | wsl)
			if command -v apt-get >/dev/null 2>&1; then
				maybe_sudo apt-get install -y -qq jq
			elif command -v dnf >/dev/null 2>&1; then
				maybe_sudo dnf install -y -q jq
			elif command -v pacman >/dev/null 2>&1; then
				maybe_sudo pacman -S --noconfirm jq
			fi
			;;
		esac
		command -v jq >/dev/null 2>&1 && ok "jq installed" || fail "jq install failed — queue queries need it; install manually."
	fi

	# --- gh CLI (for GitHub PR discovery) ---
	if command -v gh >/dev/null 2>&1; then
		ok "gh already installed"
		if gh auth status >/dev/null 2>&1; then
			ok "gh authenticated"
		else
			warn "gh is installed but not authenticated."
			warn "Run 'gh auth login' to enable PR discovery (drain pr list, status PR section)."
			warn "PR features will be skipped until authenticated."
		fi
	else
		warn "gh not found — GitHub PR discovery (drain pr list) will be skipped."
		warn "Install it to enable: brew install gh (macOS) or see https://cli.github.com"
		warn "Then run 'gh auth login'."
	fi

	# --- agent CLI (warn only) ---
	agent_found=""
	for agent in opencode claude codex; do
		if command -v "$agent" >/dev/null 2>&1; then
			agent_found="$agent_found $agent"
		fi
	done
	if [ -n "$agent_found" ]; then
		ok "agent CLIs found:$agent_found"
	else
		warn "No agent CLI found (opencode/claude/codex). Workers need one —"
		warn "install your harness of choice, or set DRAIN_AGENT accordingly."
	fi
else
	info "SKIP_DEPS=1 — skipping dependency installation"
fi

# ------------------------------------------------- TaskChampion sync server
SYNC_URL=""
if [ -n "${TASKCHAMPION_URL:-}" ]; then
	info "Using remote sync server from TASKCHAMPION_URL"
	SYNC_URL="$TASKCHAMPION_URL"
elif [ "$TASKCHAMPION_LOCAL" = "1" ] && [ "$SKIP_DEPS" != "1" ]; then
	info "Setting up local TaskChampion sync server..."
	if [ -z "$CONTAINER_RUNTIME" ]; then
		warn "No container runtime found (tried: nerdctl, docker, podman)."
		warn "Install one, or use TASKCHAMPION_URL to point at a remote sync server."
	elif "$CONTAINER_RUNTIME" ps >/dev/null 2>&1; then
		if "$CONTAINER_RUNTIME" ps --format '{{.Names}}' 2>/dev/null | grep -qx "taskchampion"; then
			ok "taskchampion container already running"
		else
			if "$CONTAINER_RUNTIME" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "taskchampion"; then
				info "Starting existing taskchampion container..."
				"$CONTAINER_RUNTIME" start taskchampion >/dev/null
			else
				info "Launching taskchampion-sync-server container (ghcr.io)..."
				mkdir -p "$HOME/.task-drain/taskchampion-data"
				"$CONTAINER_RUNTIME" run -d --name=taskchampion \
					--restart unless-stopped \
					-p 127.0.0.1:8080:8080 \
					-v "$HOME/.task-drain/taskchampion-data:/var/lib/taskchampion-sync-server/data" \
					ghcr.io/gothenburgbitfactory/taskchampion-sync-server:latest >/dev/null ||
					warn "container run failed — see manual instructions below."
			fi
		fi
		if "$CONTAINER_RUNTIME" ps --format '{{.Names}}' 2>/dev/null | grep -qx "taskchampion"; then
			SYNC_URL="http://127.0.0.1:8080"
			ok "local sync server at $SYNC_URL"
		fi
	else
		warn "Docker not available — skipping local sync server."
	fi

	if [ -z "$SYNC_URL" ]; then
		cat >&2 <<'EOF'

  To run a sync server manually:
    - Container:  $CONTAINER_RUNTIME run -d --name=taskchampion -p 127.0.0.1:8080:8080 \
                 -v ~/.task-drain/taskchampion-data:/var/lib/taskchampion-sync-server/data \
                 ghcr.io/gothenburgbitfactory/taskchampion-sync-server:latest
    - Binary:  download from https://github.com/GothenburgBitFactory/taskchampion-sync-server/releases
    - Source:  git clone https://github.com/GothenburgBitFactory/taskchampion-sync-server.git
               && cd taskchampion-sync-server && cargo build --release
  Then re-run: TASKCHAMPION_URL=http://127.0.0.1:8080 ./install.sh
EOF
	fi
else
	info "Skipping sync server setup (TASKCHAMPION_LOCAL=0 or SKIP_DEPS=1)"
fi

if [ "$TASKCHAMPION_LOCAL" = 1 ] && [ "$SKIP_DEPS" != 1 ] && [ -z "$SYNC_URL" ]; then
	fail "Requested local sync-server setup failed; no ready server was selected"
fi
# --- point taskwarrior at the sync server ---
if [ -n "$SYNC_URL" ]; then
	existing_url="$(task _get rc.sync.server.url 2>/dev/null || true)"
	if [ -n "${TASKCHAMPION_URL:-}" ]; then
		# Explicit override always wins
		task config sync.server.url "$SYNC_URL" >/dev/null
		ok "sync.server.url = $SYNC_URL (from TASKCHAMPION_URL)"
	elif [ -n "$existing_url" ] && [ "$existing_url" != "$SYNC_URL" ]; then
		warn "Preserving existing sync.server.url=$existing_url; set TASKCHAMPION_URL to override"
		SYNC_URL="$existing_url"
	else
		task config sync.server.url "$SYNC_URL" >/dev/null
		ok "sync.server.url = $SYNC_URL"
	fi

	existing_id="$(task _get rc.sync.server.client_id 2>/dev/null || true)"
	if [ -z "$existing_id" ]; then
		if command -v uuidgen >/dev/null 2>&1; then
			new_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
		else
			new_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "")"
		fi
		if [ -n "$new_id" ]; then
			task config sync.server.client_id "$new_id" >/dev/null
			ok "generated sync.server.client_id"
		else
			warn "could not generate a client_id — set one manually: task config sync.server.client_id <uuid>"
		fi
	else
		ok "sync.server.client_id already set"
	fi

	existing_secret="$(task _get rc.sync.encryption_secret 2>/dev/null || true)"
	if [ -z "$existing_secret" ]; then
		fail "sync.encryption_secret is not set. TaskChampion sync requires an encryption secret for server communication. Configure it with: task config sync.encryption_secret <secret> — then back up the secret and re-run."
	else
		ok "sync.encryption_secret is configured"
	fi

	info "Testing sync..."
	if task sync >/dev/null 2>&1; then
		ok "task sync succeeded"
	else
		fail "task sync failed; installation is not ready. Check server connectivity and pool configuration."
	fi
fi

# ---------------------------------------------------------------- scripts
info "Installing task-drain scripts..."
mkdir -p "$BINDIR"
for script in task-drain.sh drain; do
	src="$REPO_DIR/$script"
	dst="$BINDIR/$script"
	[ -f "$src" ] || fail "$src not found"
	if [ -e "$dst" ] && [ ! -L "$dst" ]; then
		info "backing up existing $dst to $dst.bak"
		[ ! -e "$dst.bak" ] || fail "Backup already exists: $dst.bak; preserve it before reinstalling"
		mv "$dst" "$dst.bak"
	fi
	ln -sf "$src" "$dst"
	chmod +x "$src"
	ok "symlinked $dst -> $src"
done
mkdir -p "$HOME/.task-drain/logs"
ok "$HOME/.task-drain/logs ready"
# Provision a default YAML template for new installations only.
# Never overwrites, never enables autonomous execution, never invents a
# primary hostname, never writes secrets. Existing installs are untouched.
if [ ! -f "$HOME/.task-drain/config.yaml" ]; then
	if command -v python3 >/dev/null 2>&1 && [ -f "$REPO_DIR/lib/drain-config.py" ]; then
		python3 "$REPO_DIR/lib/drain-config.py" template >"$HOME/.task-drain/config.yaml.tmp.$$"
		chmod 600 "$HOME/.task-drain/config.yaml.tmp.$$"
		mv "$HOME/.task-drain/config.yaml.tmp.$$" "$HOME/.task-drain/config.yaml"
		chmod 600 "$HOME/.task-drain/config.yaml"
		ok "created ~/.task-drain/config.yaml (mode 600; edit worker.primary_host only on the designated executor)"
	else
		warn "python3 not found; skipping config template (run: drain config init)"
	fi
else
	if python3 "$REPO_DIR/lib/drain-config.py" validate >/dev/null 2>&1; then
		ok "existing ~/.task-drain/config.yaml is valid"
	else
		warn "existing ~/.task-drain/config.yaml is INVALID (run: drain config validate); leaving it untouched"
	fi
fi

# ---------------------------------------------------------------- plugin
if [ "$SKIP_PLUGIN" != "1" ]; then
	PLUGIN_DIR="${PLUGIN_DIR:-$REPO_DIR/plugin}"
	if [ ! -f "$PLUGIN_DIR/package.json" ]; then
		fail "No plugin at $PLUGIN_DIR; correct PLUGIN_DIR or explicitly use SKIP_PLUGIN=1"
	else
		if command -v npm >/dev/null 2>&1; then
			info "Building task plugin at $PLUGIN_DIR..."
			(cd "$PLUGIN_DIR" && npm install --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -1)
			ok "plugin built"
			echo ""
			echo "  Enable it:"
			echo "    OpenCode plugin — opencode.json:  \"plugins\": [ \"$PLUGIN_DIR\" ],"
			echo "    MCP server (Claude Code / Cursor / Codex) — see plugin/README.md"
			echo "    Binary: $PLUGIN_DIR/dist/mcp-server.js"
		else
			fail "npm not found; install Node.js or explicitly use SKIP_PLUGIN=1"
			warn "  cd $PLUGIN_DIR && npm install && npm run build"
		fi
	fi
else
	info "SKIP_PLUGIN=1 — skipping plugin build"
fi

# ---------------------------------------------------------------- readiness verification
echo ""
info "Verifying installation..."
READY=1

# Check task binary
if command -v task >/dev/null 2>&1; then
	ok "taskwarrior found: $(task --version 2>/dev/null | head -1)"
else
	warn "taskwarrior not found — workers will not run"
	READY=0
fi

# Check jq
if command -v jq >/dev/null 2>&1; then
	ok "jq found: $(jq --version 2>/dev/null)"
else
	warn "jq not found — queue queries will fail"
	READY=0
fi

# Check agent CLI
agent_found=""
for agent in opencode claude codex; do
	if command -v "$agent" >/dev/null 2>&1; then
		agent_found="$agent_found $agent"
	fi
done
if [ -n "$agent_found" ]; then
	ok "agent CLIs found:$agent_found"
else
	warn "No agent CLI found — workers need one"
	READY=0
fi

# Check sync server connectivity
if [ -n "$SYNC_URL" ]; then
	if task sync >/dev/null 2>&1; then
		ok "sync server reachable: $SYNC_URL"
	else
		warn "sync server not reachable: $SYNC_URL"
		READY=0
	fi
else
	warn "no sync server configured"
	READY=0
fi

# Check timeout binary
if command -v gtimeout >/dev/null 2>&1; then
	ok "timeout binary: gtimeout"
elif command -v timeout >/dev/null 2>&1; then
	ok "timeout binary: timeout"
else
	warn "no timeout binary found — task timeout will not be enforced"
fi

# Check plugin
if [ "$SKIP_PLUGIN" != "1" ] && [ -f "$PLUGIN_DIR/dist/mcp-server.js" ]; then
	ok "plugin built: $PLUGIN_DIR/dist/mcp-server.js"
elif [ "$SKIP_PLUGIN" != "1" ]; then
	warn "plugin not built — run: cd $PLUGIN_DIR && npm install && npm run build"
	READY=0
fi

echo ""
if [ "$READY" = "1" ]; then
	info "Installation verified and ready."
else
	warn "Installation partially complete — fix the warnings above before starting workers."
	exit 1
fi

echo ""
info "Done. Make sure $BINDIR is on your PATH."
echo "  Then: drain docs   # read the pickup rules before starting workers"
