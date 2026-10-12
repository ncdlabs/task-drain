# Configuration

Everything is configured through environment variables (export before
`drain start`, or edit the top of `task-drain.sh`) — no config file for the
workers themselves. Project → repo mapping uses `~/.task-drain/repos.conf`.

## Worker (`task-drain.sh`)

| Variable | Default | Purpose |
|---|---|---|
| `TASK` | `task` on PATH, else `/opt/homebrew/bin/task` | Taskwarrior binary. Override with a full path. |
| `DRAIN_AGENT` | `opencode` | Agent harness: `opencode` \| `claude` \| `codex`. Selects the invocation (`opencode run --standalone …`, `claude -p`, `codex exec`). Unknown values abort the worker. |
| `OPENCODE_BIN` | `opencode` | Agent binary (only used when `DRAIN_AGENT=opencode`) |
| `DRAIN_MODEL` | `opencode-go/longcat-2.5-preview-free` | Model for worker runs (opencode only; override per run) |
| `OPENCODE_RUN_FLAGS` | `--standalone --model $DRAIN_MODEL` | Raw flags for `opencode run`. **Warning:** an invalid flag fails every task attempt and mass-marks the queue `drain-failed`. Test one task after changing flags. |
| `DRAIN_SKIP_PERMISSIONS` | `0` | Set to `1` to append `--dangerously-skip-permissions`. Without it, unattended runs stall on the first approval prompt. **This is the main risk dial** — only enable if you trust the worker to operate without human approval. |
| `DRAIN_OWNER` | `the project owner` | Human authority named in the worker prompt for design/security/product decisions. Workers must annotate and fail instead of deciding. |
| `GIT_ROOT` | `$HOME/git` | Where repos live; used for project → repo auto-detection |
| `PROJECT_FILTER` | (unset) | Limit a worker run to one project (normally set via `drain start N <project>`) |
| `DRAIN_RETRY_FAILED` | `0` | `1` = reprocess `drain-failed` tasks instead of the regular queue (normally set via `drain start --failed`) |
| `DRAIN_PERSIST` | `0` | `1` = wait for new jobs after the queue empties instead of exiting (normally set via `drain start --persist`) |
| `DRAIN_PERSIST_POLL_SEC` | `10` | Seconds between queue polls in persist mode |
| `STALE_AFTER_SEC` | `14400` (4h) | Worker claims active longer than this with no completion are released. Only worker claims — interactive agents' tasks are never touched. |
| `TASK_TIMEOUT_SEC` | `14400` (4h) | Per-task wall clock, enforced with `gtimeout` (coreutils). Without `gtimeout`, tasks run unbounded. Timed-out tasks are marked failed, not retried. |
| `DRAIN_SYNC_RETRY_DELAY` | `3` | Base seconds between sync retries (exponential backoff, 3 attempts) |
| `DRAIN_HISTORY_LIMIT` | `20` | Rolling-window size for `drain history` |
| `DRAIN_ERROR_WEBHOOK` | (unset) | Slack/Discord webhook URL. Critical worker failures are POSTed here (and always logged locally). |
| `DRAIN_DEBUG` | `0` | Set to `1` for verbose worker logging |
| `TASKRC` | (unset) | Passed through to the sudo sync fallback so the task DB stays user-owned |

## Autoscaler

| Variable | Default | Purpose |
|---|---|---|
| `DRAIN_MIN_WORKERS` | `1` | Minimum workers to keep running (normally set via `drain autoscale --min`) |
| `DRAIN_MAX_WORKERS` | `8` | Maximum workers to start (normally set via `drain autoscale --max`) |
| `DRAIN_AUTOSCALE_INTERVAL` | `30` | Seconds between queue-depth checks |
| `DRAIN_TASKS_PER_WORKER` | `2` | Eligible tasks per worker before scaling up (clamped to ≥ 1) |

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
| `noauto` | you | Opt out of worker pickup. Workers never touch these. |
| `drain-failed` | workers | A worker attempt ended without completion. Regular workers skip it; clear with `task <uuid> modify -drain-failed` or retry the set with `drain start N --failed`. |
| `drain-claimed` | workers | In-flight marker while a worker owns a task. Auto-released after `STALE_AFTER_SEC` if the worker dies. Never set it by hand. |

## Project → repo mapping (`~/.task-drain/repos.conf`)

One `project=path` per line, `#` comments and blank lines allowed.
Takes precedence over auto-detection and the built-in table:

```
# primary mapping — checked first
myproject=$HOME/git/myrepo
website=~/git/website
```

`~` and `$HOME` are expanded. `drain projects` shows the effective mapping
from all three sources. Tasks with no resolvable repo run with `$HOME` as
their working directory.
