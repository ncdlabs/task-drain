# Installation

Install shell workers, the task plugin, or both. `install.sh` installs script
symlinks and builds the plugin by default; it does not enable the plugin in
an agent client or start workers.

## Prerequisites

| Requirement | Purpose |
|---|---|
| Taskwarrior 3.x and configured TaskChampion sync | Shared task pool. The installer checks major version ≥3; workers do not independently enforce a version check. |
| Bash and jq | Worker scripts and JSON processing. Use Bash 4+ for development; the installer does not install Bash. |
| Authenticated agent CLI | OpenCode v2 (default), Claude Code, or OpenAI Codex for workers; unnecessary for the standalone MCP server itself. |
| Node.js 20+ and npm | Plugin build/runtime, per `plugin/package.json`. Current development tests require Node.js 22+ with type stripping. |
| `gtimeout` (optional) | Per-task timeout. Only this executable name is detected; Linux `timeout` alone does not enable the limit. |
| Git and forge credentials | Needed for code tasks; authenticated `gh` also enables GitHub PR discovery. |
| Container runtime (optional) | Installer checks nerdctl, Docker, then Podman for a local sync server. |

The scripts target macOS and Linux/WSL. Native Windows workers are rejected
by the installer. Both shell entry points replace PATH; see
[configuration](configuration.md#environment-and-process-scope) if a binary
is installed elsewhere. The installer only installs Taskwarrior and jq;
install the remaining prerequisites separately.

## Configure the task pool first

For an existing pool, obtain its URL, client ID, and encryption secret through
your team's credential channel. Replicas sharing tasks use the **same client
ID and encryption secret**, with separate local data directories. A new
client ID creates an independent server-side user/pool. Do not regenerate
an existing profile's identity as a troubleshooting step. See the official
[Taskwarrior sync manual](https://taskwarrior.org/docs/man/task-sync.5/).

For a new profile, set these values (replace placeholders before running):

```bash
task config sync.server.url https://your-sync-server.example
task config sync.server.client_id '<pool-client-id>'
task config sync.encryption_secret '<pool-encryption-secret>'
task sync
```

Create a new UUID only when creating a new pool. Keep credentials out of
repositories and shared command transcripts. For another replica, start with
an empty local data directory and the existing pool configuration. Export
`TASKRC` when using a nondefault profile; Taskwarrior inherits it for ordinary
commands as well as the worker's sudo fallback.

## Automated install

```bash
git clone https://github.com/ncdlabs/task-drain.git
cd task-drain
TASKCHAMPION_LOCAL=0 ./install.sh  # preserve an already configured sync setup
```

For a new local sync server, use `./install.sh` without that override. Review
these side effects before running it:

1. Installs Taskwarrior and jq if missing, unless `SKIP_DEPS=1`.
2. With local setup enabled, starts/reuses `taskchampion`, binds a new
   container to `127.0.0.1:8080`, and mounts
   `~/.task-drain/taskchampion-data`. The image uses `:latest`; this is not a
   pinned production deployment. A running container is not a health check.
3. If it selects a sync URL, attempts profile configuration and a real
   `task sync`. It may generate a missing client ID. Its `task show | awk`
   probes are fragile; verify the resulting settings yourself. A differing
   existing URL is preserved even with `TASKCHAMPION_URL` supplied, despite
   the installer's override message. Set the profile deliberately beforehand.
4. Warns about a missing encryption secret but still attempts sync. The
   warning about unencrypted sync is misleading: TaskChampion server sync
   uses encrypted task data; configure the secret and verify sync explicitly.
5. Symlinks `drain` and `task-drain.sh` into `$PREFIX/bin` (default `~/bin`),
   backing up existing non-symlink files as `.bak`. Repeated installation can
   replace a previous `.bak` file.
6. Builds `plugin/` using npm unless skipped. Client configuration remains manual.

| Installer variable | Effect |
|---|---|
| `PREFIX=/usr/local` | Install links into `/usr/local/bin`; caller needs write access |
| `SKIP_DEPS=1` | Skip dependency installation and automatic local server setup |
| `SKIP_PLUGIN=1` | Skip plugin build |
| `TASKCHAMPION_URL=https://…` | Select remote setup instead of creating a local container; does not reliably override an existing URL |
| `TASKCHAMPION_LOCAL=0` | Disable automatic local server setup; an explicit URL still enables remote setup |
| `CONTAINER_RUNTIME` | Override nerdctl → Docker → Podman detection |
| `PLUGIN_DIR` | Override `<repo>/plugin` |

Do not treat a successful installer exit as proof that sync or agent access
works; some failures produce warnings and installation continues.

## Manual script install

From the repository root, after installing prerequisites and configuring sync:

```bash
mkdir -p "$HOME/bin"
ln -s "$PWD/drain" "$HOME/bin/drain"
export PATH="$HOME/bin:$PATH"
drain help
```

Keep `task-drain.sh` and `lib/` in the clone. `drain` resolves its own symlink
and locates them. The worker script itself does not resolve symlinks; use
`bash /absolute/path/to/task-drain/task-drain.sh` for direct modes. Copying
only the two scripts into a bin directory omits required libraries.

## Plugin install (task layer only)

From the repository root:

```bash
(cd plugin && npm ci && npm run build)
```

OpenCode **v2** uses this configuration:

```json
{ "plugins": ["/absolute/path/to/task-drain/plugin"] }
```

The plural `plugins` key and `@opencode/plugin` API target v2; v1 plugin
examples are not interchangeable. See the official
[OpenCode v2 plugin guide](https://opencode.ai/v2/docs/build/plugins/).
The installer's printed singular `plugin` example is stale for this adapter.

For an MCP client, launch `node` with the absolute path to
`plugin/dist/mcp-server.js` over stdio. No port or HTTP service is opened.
Configure `TASK_BIN` and `TASKRC` in the client environment if necessary;
leave automatic sync enabled for normal shared-pool use.
[Plugin README](../plugin/README.md#mcp-server-taskwarrior-mcp) contains client
configuration examples; [tool reference](plugin-tools.md) defines behavior.

## Verification and first worker

```bash
task --version
task sync
drain help
drain projects
DRAIN_AUTONOMOUS=1 drain status myproject
```

The installer provisions `~/.task-drain/config.yaml` (mode 600) for new
installations only: defaults, no autonomous execution, no invented primary
host. Existing files are never overwritten (`drain config init` also refuses
when the file exists). Validate with `drain config validate` and inspect with
`drain config show`. See the canonical [configuration](configuration.md).

Configure project checkouts before starting workers (YAML first, legacy
`~/.task-drain/repos.conf` still honored):

```text
myproject=$HOME/git/myrepo
other=~/git/other
```

Resolution order is exact config match, exact directory name under
`GIT_ROOT`, then the built-in table. Missing/nonexistent mappings fall back
to HOME. Confirm the actual task project, including subproject suffixes.

Check the selected agent's noninteractive help and authenticate it before a
run (`opencode run --help`, `claude --help`, or `codex exec --help`). Configure
its permissions deliberately. Tag one reviewed task `auto`, sync, then run
`DRAIN_AUTONOMOUS=1 drain start 1 myproject`. Inspect `drain logs`; launch
success only means a process was spawned, not that it passed startup checks.

## Sync failures and macOS Local Network Privacy

The worker tries normal sync, then `sudo env HOME=… TASKRC=… <task> sync` on
**any** failure, on all platforms. It retries that pair up to three times.
This was introduced for a reported macOS LAN-access issue; it is not proof
that every connection error is a privacy denial. The plugin has no sudo fallback.

Preserving HOME/TASKRC does not preserve effective user identity or guarantee
file ownership. Sudo policy must permit the exact invocation; a rule for the
task binary alone may not authorize `sudo env …`. Repair connectivity and
normal-user permissions first. Do not grant unrestricted passwordless `env`
as a workaround. See [troubleshooting](troubleshooting.md).
