# CLI reference

Two entry points: `drain` (the human interface) and `task-drain.sh` (the
worker itself, usually launched via `drain`). Both are executable directly.

## `drain`

```
drain                show help
drain help [cmd]     detailed help (also: drain <cmd> help)
```

### `drain status [project] [-w|--watch] [--workers] [-v|--verbose]`

Queue dashboard: sync state, kill-switch/autoscale state, worker count,
eligible/next tasks, in-progress list, needs-attention flags (orphaned,
stuck, unlinked, stale, or long-idle-manual tasks), failed tasks needing
review, and today's drain completions. Optionally scoped to one project
(`all` or no argument = everything).

- `-w` / `--watch` — live display, refreshes every `DRAIN_WATCH_INTERVAL`
  seconds (default 5); `q` quits. First frame syncs; refreshes reuse local
  state.
- `--workers` — per-worker view instead: each worker's current task plus a
  time-budget meter (elapsed vs `TASK_TIMEOUT_SEC`). With a project filter,
  other projects are dimmed.
- `-v` / `--verbose` (or `DRAIN_VERBOSE=1`) — full lists instead of the
  capped summary.

The first frame syncs; on sync failure it shows local state with a warning.

### `drain start [N] [project|all] [--failed] [--persist]`

Start N background workers (default 2, max 8), optionally limited to one
project. Clears a stale global STOP file and prunes dead per-worker STOP
files first. Each worker logs to
`~/.task-drain/logs/worker-<timestamp>-<pid>-N.log`.

- `--failed` — reprocess `drain-failed` tasks instead of the regular queue.
  The failed set is snapshotted per worker at startup; each task gets at
  most one retry per run, so nothing loops.
- `--persist` — workers wait for new jobs (polling every
  `DRAIN_PERSIST_POLL_SEC`, default 10s) after the queue empties instead
  of exiting.

Examples:

```bash
drain start                  # 2 workers, all projects
drain start 4 myproject       # 4 workers, one project
drain start 2 --failed        # retry the failed set, all projects
drain start 2 myproject --persist
```

### `drain stop [N|all] [--force]`

- No arg / `all` — graceful stop of all workers: no new pickups, in-flight
  tasks finish, workers exit. Implemented via the global
  `~/.task-drain/STOP` file.
- `N` — gracefully stop N workers (newest first) via per-worker
  `STOP.<pid>` files. `N >= running` stops all.
- `--force` — immediate: TERM mid-task (same as `drain kill`). In-flight
  tasks are released back to pending. Also stops the autoscaler.

### `drain kill`

Immediate stop: TERM all workers mid-task. In-flight claims are released
back to pending by each worker's signal handler. **Also stops the autoscale
supervisor**, so it can't respawn the workers.

### `drain autoscale [project] [--min N] [--max N]`

Supervisor daemon: watches queue depth and scales workers to match —
`ceil(eligible / DRAIN_TASKS_PER_WORKER)`, clamped to `[--min, --max]`
(defaults 1 and 8; env: `DRAIN_MIN_WORKERS`, `DRAIN_MAX_WORKERS`).
Checks every `DRAIN_AUTOSCALE_INTERVAL` seconds (default 30). Scale-down is
graceful (per-worker STOP files — workers finish their current task).
Exits on the global STOP file or SIGTERM. PID tracked in
`~/.task-drain/autoscale.pid`.

```bash
drain autoscale                       # min 1, max 8, all projects
drain autoscale myproject --min 2 --max 4
drain autoscale --min 0 --max 10      # scales to zero when the queue is empty
```

### `drain autoscale-stop`

Stop the autoscaler daemon. Workers already running are **not** affected —
they keep working until the queue empties or they are stopped.

### `drain unfail [project]`

Remove the `drain-failed` tag from failed tasks, returning them to the
regular queue. Lists what it will re-queue first.

### `drain resume`

Clear the global STOP file and all per-worker `STOP.<pid>` files. Does not
start workers — follow with `drain start`.

### `drain logs [-f]`

Tail the last 30 lines of each worker log (`-f` follows all of them).

### `drain history [--limit N]`

Processed-task history from `~/.task-drain/history.log` (rolling window,
default 20 entries, see `DRAIN_HISTORY_LIMIT`): totals, success rate,
average duration, and a most-recent-first table.

### `drain projects`

List project → repo mappings from all three sources (`repos.conf`,
built-in table, auto-detected repos) plus projects that currently have
pending tasks.

### `drain projects merge <destination> <source...>`

Move **all** tasks from each source project into the destination project
(all statuses — pending, active, waiting, completed). Needs at least a
destination and one source; refuses to merge a project into itself. Run
`task sync` afterwards. If any source had a `repos.conf` mapping, you're
reminded to update it.

### `drain pr list [--json]`

List open pull requests across all configured repos whose body references
a task UUID (created by drain workers via the git workflow). Shows repo,
PR number, title, URL, and linked task UUID. Use `--json` for raw JSON
output. Also surfaced in `drain status` under **PENDING APPROVAL**.

### `drain docs`

The extended operator manual: pickup rules, tags, retrying failed tasks,
the agent prompt contract, stopping, and safety dials. Read this before
your first `drain start`.

## `task-drain.sh` direct modes

Normally launched via `drain`, but runnable directly:

```bash
bash task-drain.sh [run|status|history|watch|workers|autoscale]
```

| Mode | Behavior |
|---|---|
| `run` (default) | Run one worker: loop until the queue is empty (or STOP), then exit |
| `autoscale` | Run the autoscale supervisor daemon |
| `status` | One-shot queue dashboard (same renderer as `drain status`) |
| `history` | One-shot history view |
| `watch` | Live `status` display (`q` quits) |
| `workers` | Live per-worker view |

## State files (`~/.task-drain/`)

| Path | Purpose |
|---|---|
| `STOP` | Global kill switch — graceful stop for workers and autoscaler |
| `STOP.<pid>` | Per-worker graceful stop |
| `autoscale.pid` | Running autoscaler supervisor PID |
| `repos.conf` | Project → repo mappings (highest precedence) |
| `history.log` | Processed-task history (TSV, rolling window) |
| `logs/` | Per-worker logs |
