# Configuration

Everything is configured through environment variables (export before
`drain start`) — no config file for the
workers themselves. Project → repo mapping uses `~/.task-drain/repos.conf`.

## Worker (`task-drain.sh`)

| Variable | Default | Purpose |
|---|---|---|
| `TASK` | `task` on PATH, else `/opt/homebrew/bin/task` | Taskwarrior binary. Override with a full path. |
| `DRAIN_AGENT` | `opencode` | Agent harness: `opencode` \| `claude` \| `codex`. Selects the invocation (`opencode run --standalone …`, `claude -p`, `codex exec`). Unknown values abort the worker. |
| `OPENCODE_BIN` | `opencode` | Agent binary (only used when `DRAIN_AGENT=opencode`) |
| `DRAIN_MODEL` | `opencode-go/longcat-2.5-preview-free` | Model for worker runs (opencode only; override per run) |
| `OPENCODE_RUN_FLAGS` (internal array) | `--standalone --model "$DRAIN_MODEL"` | Not an environment override: the script unconditionally assigns this array. Changing additional flags requires a source change. |
| `DRAIN_SKIP_PERMISSIONS` | `0` | Set to `1` to append `--dangerously-skip-permissions` to OpenCode only. Claude and Codex use their own configured permissions; this variable does not change them. Approval behavior depends on the installed harness. |
| `DRAIN_OWNER` | `the project owner` | Human authority named in the worker prompt for design/security/product decisions. Workers must annotate and fail instead of deciding. |
| `GIT_ROOT` | `$HOME/git` | Where repos live; used for project → repo auto-detection |
| `PROJECT_FILTER` | (unset) | Limit a worker run to one project (normally set via `drain start N <project>`) |
| `DRAIN_RETRY_FAILED` | `0` | `1` = reprocess `drain-failed` tasks instead of the regular queue (normally set via `drain start --failed`) |
| `DRAIN_PERSIST` | `0` | `1` = wait for new jobs after the queue empties instead of exiting (normally set via `drain start --persist`) |
| `DRAIN_AUTONOMOUS` | `0` | `1` = opt-in pickup: only tasks tagged `+auto` are eligible (normally set via `drain start --autonomous`, which also launches the autoscaler) |
| `DRAIN_PERSIST_POLL_SEC` | `10` | Seconds between queue polls in persist mode |
| `STALE_AFTER_SEC` | `14400` (4h) | Active `drain-claimed` tasks older than this are released by a running worker, even if their agent is still alive. Reclamation is global, not project-scoped. |
| `TASK_TIMEOUT_SEC` | `14400` (4h) | Per-task wall clock, enforced with `gtimeout` (coreutils). Without `gtimeout`, tasks run unbounded. Timed-out tasks are marked failed, not retried. |
| `DRAIN_SYNC_RETRY_DELAY` | `3` | Base seconds between sync retries (exponential backoff, 3 attempts) |
| `DRAIN_HISTORY_LIMIT` | `20` | Rolling-window size for `drain history` |
| `DRAIN_ERROR_WEBHOOK` | (unset) | Webhook accepting a JSON `text` field (for example Slack). Selected error paths POST worker, hostname, and error details; not every task failure triggers it. Discord compatibility is not implemented explicitly. |
| `DRAIN_DEBUG` | `0` | Set to `1` for verbose worker logging |
| `TASKRC` | (unset) | Taskwarrior profile; forwarded to sudo sync with HOME. Does not guarantee file ownership or forward TASKDATA explicitly |

## Autoscaler

| Variable | Default | Purpose |
|---|---|---|
| `DRAIN_MIN_WORKERS` | `1` | Minimum workers to keep running (normally set via `drain autoscale --min`) |
| `DRAIN_MAX_WORKERS` | `8` | Maximum workers to start (normally set via `drain autoscale --max`) |
| `DRAIN_AUTOSCALE_INTERVAL` | `30` | Seconds between queue-depth checks (the poll sleep is interruptible, so SIGTERM stops the supervisor promptly) |
| `DRAIN_TASKS_PER_WORKER` | `2` | Eligible tasks per worker before scaling up (invalid or nonpositive values reset to 2) |
| `DRAIN_STARTUP_LOCK_MAX_AGE_SEC` | `120` | A `drain autoscale` launch mutex older than this is treated as stale (crashed starter) and broken by the next starter |

Desired workers = `ceil(eligible / DRAIN_TASKS_PER_WORKER)`, clamped to
`[min, max]`; `0` eligible with `min 0` scales to zero.

## Display (`drain status` / `watch` / `workers`)

| Variable | Purpose |
|---|---|
| `DRAIN_VERBOSE=1` | Full lists instead of the capped summary (same as `--verbose`) |
| `DRAIN_WATCH_INTERVAL` | Seconds between live-display refreshes (default 5, minimum 2) |
| `DRAIN_FORCE_COLOR=1` | Force color output when piping |
| `NO_COLOR` | Respected — disables color |
| `COLUMNS` | Display width (auto-detected, clamped 40–200) |

## Installer (`install.sh`)

| Variable | Effect |
|---|---|
| `PREFIX` | Install scripts to `$PREFIX/bin` instead of `~/bin` |
| `SKIP_DEPS=1` | Skip dependency installation |
| `SKIP_PLUGIN=1` | Skip the plugin build |
| `TASKCHAMPION_URL` | Use this sync server URL instead of starting a local one |
| `TASKCHAMPION_LOCAL=0` | Don't set up a local sync server |
| `CONTAINER_RUNTIME` | Override auto-detection (tries nerdctl → docker → podman) |
| `PLUGIN_DIR` | Plugin location (default `<repo>/plugin`) |

## Plugin (`plugin/`)

| Option | Env | Default |
|---|---|---|
| `taskBin` | `TASK_BIN` | `/opt/homebrew/bin/task` if present, else `task` on PATH |
| `taskrc` | `TASKRC` | Default `~/.taskrc` pool |
| `autoSync` | `TASK_AUTO_SYNC=0` disables | `true` — sync before reads, around writes |

## Tags

| Tag | Set by | Meaning |
|---|---|---|
| `noauto` | you | Excludes default-mode pickup, but is not excluded in autonomous mode. |
| `auto` | you | Opt in to worker pickup in autonomous mode (`DRAIN_AUTONOMOUS=1` / `--autonomous`). Only these tasks are eligible. |
| `drain-failed` | workers | A worker attempt ended without completion. Regular workers skip it; clear with `task <uuid> modify -drain-failed` or retry the set with `drain start N --failed`. |
| `drain-claimed` | workers | In-flight marker while a worker owns a task. Released based on active age by a running worker; no process-liveness check. Never set it by hand. |

## Project → repo mapping (`~/.task-drain/repos.conf`)

One `project=path` per line, `#` comments and blank lines allowed.
Takes precedence over auto-detection and the built-in table:

```
# primary mapping — checked first
myproject=$HOME/git/myrepo
website=~/git/website
```

Only a leading `~` and literal `$HOME` are expanded; this is not a shell
file (do not quote paths or put spaces around `=`). The first exact project
match wins. Precedence is `repos.conf`, matching directory under `GIT_ROOT`,
then the built-in table. `drain projects` lists sources, not a deduplicated
resolution report. Subprojects need their own mappings. Tasks with no resolvable repo run with `$HOME` as
their working directory.

## Environment and process scope

Both shell entry points replace PATH with `/opt/homebrew/bin:/usr/local/bin:$HOME/.opencode/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
Use an absolute `TASK` or `OPENCODE_BIN` when needed. Claude and Codex must
be available on that PATH. Worker `TASK` and plugin `TASK_BIN` are different
settings; configure both if they should use the same binary.

Configuration is inherited at launch. Changing an export does not reconfigure
existing workers or the autoscaler. `DRAIN_AUTONOMOUS=1 drain start 1` changes
pickup without starting a supervisor; `drain start --autonomous` does both.
An existing supervisor is reused without changing its settings. Stop and
restart it explicitly to change its project or pickup mode.

`PROJECT_FILTER` already exported in the shell can survive `drain start all`
and `drain autoscale all`; unset it explicitly for an unrestricted launch.
Worker detection, stop files, history, worker registry, and the supervisor PID file are shared
under HOME, not isolated by project or TASKRC. Supervisor single-instance
state is host-local (PID plus command-line identity with a transient launch
mutex); it does not coordinate supervisors across machines. Direct supervisor mode also
accepts `DRAIN_SCRIPT` and `LOG_DIR`; these are internal launch controls.
`DRAIN_NO_SYNC` suppresses dashboard sync when nonempty and is set internally
on watch refreshes. It is not a worker offline-mode switch.

The default OpenCode model string is a source default, not a guarantee of
provider availability or price. Validate it in your installed harness before
starting a queue. Invalid agent flags or unavailable models can fail every
eligible task in succession.

## YAML Configuration (config.yaml)

Configuration is centralized in `~/.task-drain/config.yaml` (override with `$DRAIN_CONFIG`).
Environment variables still work and take precedence over the config file.

```yaml
# Remote hosts for drain CLI management
remotes:
  llama:
    ssh: /home/hatch/bin/llama-ssh   # SSH helper command
    git_root: /Users/lou/git          # for reference

# Default remote for `drain` commands (empty = local)
default_remote: llama

# Autoscaler defaults
autoscaler:
  min_workers: 1
  max_workers: 8
  interval: 30

# Worker defaults (replaces DRAIN_* env vars)
worker:
  allow_sudo: false    # DRAIN_ALLOW_SUDO — opt-in privilege fallback for macOS daemons
  allow_home: false    # DRAIN_ALLOW_HOME — use $HOME when no repo mapping exists
  autonomous: false    # DRAIN_AUTONOMOUS — opt-in pickup (requires +auto tag)
  retry_failed: false  # DRAIN_RETRY_FAILED — reprocess drain-failed tasks
  persist: false       # DRAIN_PERSIST — wait for new jobs after queue empties

# Repository mappings (replaces repos.conf)
# path: local checkout path (auto-detected as $GIT_ROOT/<project> if omitted)
# url: remote URL for auto-clone when the repo is missing
repos:
  wp-solfoundation-plugin:
    url: https://github.com/The-Sol-Foundation/wp-solfoundation-plugin.git
  myproject:
    path: ~/custom/path
    url: git@github.com:org/myproject.git
```

### Remote management

If `default_remote` is set, `drain` commands run on the remote host:

```bash
drain status              # runs on default_remote (llama)
drain --local status      # force local execution
drain --remote llama stop # explicit remote
```

The remote is accessed via the `ssh` command from the config.

### Auto-clone

When a worker needs a repo that isn't checked out locally, it looks up
`repos.<project>.url` from the config and clones it to `$GIT_ROOT/<project>`.
If no URL is configured, the task is parked with `drain-failed`.
