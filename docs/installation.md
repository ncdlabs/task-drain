# Installation

task-drain has two installable pieces that work independently:

1. **The worker pool** (`task-drain.sh` + the `drain` CLI) — autonomous agents
   that burn down your Taskwarrior queue. See [Operating modes](operating-modes.md).
2. **The task plugin** (`plugin/`) — 22 Taskwarrior tools for interactive agent
   sessions (OpenCode plugin or MCP server). Install it even if you never run
   a worker.

`./install.sh` sets up both. Everything below is also doable by hand.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Taskwarrior 3.x** | Hard requirement — TaskChampion sync is built into 3.x. 2.x cannot sync and workers refuse to run. |
| **A TaskChampion sync server** | The shared pool is what makes multi-machine workers possible. Self-host via Docker (`ghcr.io/gothenburgbitfactory/taskchampion-sync-server`), the binary release, or `cargo build --release`. There is currently no public hosted service. |
| **An agent CLI** on PATH | Pick one with `DRAIN_AGENT`: `opencode` (v2, default), `claude` (Claude Code), `codex` (OpenCode). Workers need one; the plugin-only mode does not. |
| **jq** | Queue queries are parsed with `jq`. |
| **gtimeout** (optional) | From coreutils. Enables the per-task wall clock (`TASK_TIMEOUT_SEC`); without it tasks run unbounded. |
| **bash 4+** | |
| **Node.js** (plugin only) | For building `plugin/` (`npm install && npm run build`). |

Primarily tested on **macOS** (Homebrew). Linux works if `task`, your agent
CLI, and `jq` are on PATH.

### macOS 26+ note: Local Network Privacy

macOS 26 may block third-party (e.g. Homebrew) binaries from reaching a LAN
taskserver (`EHOSTUNREACH`). `task-drain.sh` falls back to `sudo task sync`
— root bypasses LNP, and the DB stays user-owned because sudo runs with your
`HOME`/`TASKRC`. This needs NOPASSWD for the task binary in sudoers.
Alternatively, grant the agent binary Local Network permission in
System Settings → Privacy & Security → Local Network.

## Automated install

```bash
git clone https://github.com/ncdlabs/task-drain.git
cd task-drain
./install.sh
```

The installer is idempotent — safe to re-run. It does, in order:

1. **Dependencies** — installs Taskwarrior 3.x (Homebrew on macOS;
   apt/dnf/pacman on Linux) and `jq` if missing; verifies `task --version`
   is 3.x. Warns if no agent CLI is on PATH.
2. **Sync server** — starts a local TaskChampion sync server via Docker if
   available, then configures `task` with `sync.server.url` and generates a
   `sync.server.client_id` if you don't have one. Honors `TASKCHAMPION_URL`
   to use a remote server instead, or `TASKCHAMPION_LOCAL=0` to skip.
   Warns (does not silently sync) if `sync.encryption_secret` is unset.
3. **Scripts** — symlinks `task-drain.sh` and `drain` into `~/bin/`, so
   `git pull` in the repo updates your install. Set `PREFIX=/usr/local` to
   install into `/usr/local/bin` instead.
4. **Task plugin** — builds `plugin/` (`npm install` + `npm run build`).
   Skip with `SKIP_PLUGIN=1`, override the path with `PLUGIN_DIR=`.

Installer knobs (environment variables):

| Variable | Effect |
|---|---|
| `PREFIX` | Install scripts to `$PREFIX/bin` instead of `~/bin` |
| `SKIP_DEPS=1` | Skip dependency installation (`task`, `jq`) |
| `SKIP_PLUGIN=1` | Skip the plugin build |
| `TASKCHAMPION_URL=https://…` | Use this sync server instead of starting a local one |
| `TASKCHAMPION_LOCAL=0` | Don't set up a local sync server at all |
| `CONTAINER_RUNTIME` | Override container runtime auto-detection (tries nerdctl → docker → podman) |
| `PLUGIN_DIR=/path` | Plugin location (default: `<repo>/plugin`) |

After installing, make sure `$PREFIX/bin` (default `~/bin`) is on your PATH,
then run `drain docs` and read the pickup rules before starting workers.

## Manual install (without install.sh)

1. Install Taskwarrior 3.x, `jq`, and your agent CLI of choice.
2. Point Taskwarrior at your sync server:
   ```bash
   task config sync.server.url https://your-sync-server.example
   task config sync.server.client_id "$(uuidgen | tr '[:upper:]' '[:lower:]')"
   ```
   Each machine needs its **own** `client_id` and its **own** `data.location`.
   Never change the client ID afterwards, and never share one local data dir
   between two identities — both corrupt sync state.
3. `task sync` — workers abort on startup if the initial sync fails
   ("never work offline").
4. Symlink (or copy) `task-drain.sh` and `drain` somewhere on your PATH:
   ```bash
   ln -s "$PWD/task-drain.sh" ~/bin/task-drain.sh
   ln -s "$PWD/drain" ~/bin/drain
   ```
   Both scripts resolve symlinks to find their siblings and `lib/`.

## Plugin install (task layer only)

You don't need workers to use the 22 task tools — see
[Operating modes](operating-modes.md#mode-1-task-layer-only-no-workers).

Build once:

```bash
cd plugin && npm install && npm run build
```

Then either:

- **OpenCode plugin** — in `opencode.json(c)`:
  ```jsonc
  { "plugins": ["<path-to-task-drain>/plugin"] }
  ```
- **MCP server** (`taskwarrior-mcp`, stdio) — point your client at
  `<path-to-task-drain>/plugin/dist/mcp-server.js`:
  ```sh
  # Claude Code
  claude mcp add taskwarrior -- node /path/to/task-drain/plugin/dist/mcp-server.js
  ```
  Cursor (`~/.cursor/mcp.json`), OpenCode (`opencode.json` `mcp` section),
  and Codex (`~/.codex/config.toml`) equivalents are in
  [plugin/README.md](../plugin/README.md#mcp-server-taskwarrior-mcp).

  Configure via environment: `TASK_BIN`, `TASKRC`, `TASK_AUTO_SYNC=0`.

## Verifying the install

```bash
drain docs        # pickup rules, tags, kill switch — read this first
drain status      # syncs, then shows workers / queue / failed tasks
drain projects    # check your project → repo mappings
```

If `drain status` reports `sync: FAILED`, fix sync before starting workers —
they will refuse to start while offline, by design.

## Project → repo mapping

Workers run each task's agent with the project's repo as its working
directory. Configure the mapping before your first run:

1. `~/.task-drain/repos.conf` (highest precedence, one per line):
   ```
   myproject=$HOME/git/myrepo
   other=~/git/other
   ```
2. Auto-detect: a directory named exactly like the project under `$GIT_ROOT`
   (default `~/git`).
3. Built-in table in `task-drain.sh` (examples — edit for your projects).

Tasks whose project has no mapping (or whose directory doesn't exist) run
with `$HOME` as the working directory. Review with `drain projects`.
