# CLI reference

Two entry points: `drain` (the human interface) and `task-drain.sh` (the
worker itself, usually launched via `drain`). Invoke the worker through its real repository path; unlike `drain`, it does
not resolve symlinks before loading `lib/`.

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

### `drain start [N] [project|all] [--failed] [--persist] [--autonomous]`

Start N additional background workers (default 2, max 8 per invocation), optionally limited to one
project. Clears a stale global STOP file and prunes dead per-worker STOP
files first. Each worker logs to
`~/.task-drain/logs/worker-<timestamp>-<pid>-N.log`.

- `--failed` — reprocess `drain-failed` tasks instead of the regular queue.
  The failed set is snapshotted per worker at startup; each task gets at
  most one retry per worker snapshot. Multiple workers can retry the same
  task; this is not a pool-wide guarantee. Retry selection rechecks pending,
  failed, and idle state, but does not recheck all original eligibility filters.
- `--persist` — workers wait for new jobs (polling every
  `DRAIN_PERSIST_POLL_SEC`, default 10s) after the queue empties instead
  of exiting.
- `--autonomous` — opt-in pickup mode: only tasks tagged `+auto` are
  eligible (`noauto` still excludes in this mode, matching the current
  filter). Also launches the autoscaler;
  `DRAIN_AUTONOMOUS=1` alone does not. An existing supervisor retains its
  previous configuration. The initial N does not cap autoscaler growth.

Examples:

```bash
drain start                  # 2 workers, all projects
drain start 4 myproject       # 4 workers, one project
drain start 2 --failed        # retry the failed set, all projects
drain start 2 myproject --persist
drain start --autonomous     # opt-in mode; launches autoscaler
```

### `drain stop [N|all] [--force]`

- No arg / `all` — graceful stop of all workers: no new pickups, in-flight
  tasks finish, workers exit. Implemented via the global
  `~/.task-drain/STOP` file.
- `N` — gracefully stop N workers (newest first) via per-worker
  `STOP.<pid>` files. `N >= running` stops all.
- `--force` — immediate: TERM mid-task (same as `drain kill`). Claim release and sync are best-effort. Also stops the autoscaler (before checking worker count). `N` cannot be combined with `--force`.

### `drain kill`

Immediate stop: send TERM to matching local workers. Their signal handlers
attempt to terminate the direct child, release claims, and sync; descendants
and failed cleanup can survive. It does not wait for all work to stop. **Also stops the autoscale
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

Remove `drain-failed` from pending tasks (optionally scoped by project).
The implementation selects `status:pending` tasks carrying `drain-failed`;
there is no `noauto` exclusion. Lists them and modifies
immediately; there is no confirmation prompt. It does not sync before or
after, and does not require `auto` in autonomous mode. Run `task sync`
before and after when sharing a pool.

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

Attempts a project-wide `task project:<source> modify project:<destination>`.
Every named source is processed with exact project matching (descendants
must be named explicitly) across `pending`, `waiting`, `completed`,
`recurring`, and `deleted` statuses; a source with no matching tasks moves
nothing. Each mutation is verified by re-export and only verified moves are
counted (`Verified N task(s) moved`). Modification or verification failures
abort with an error, and changes are synced automatically. Treat output as
advisory until confirmed: export and check source/destination tasks before
and after, then sync. Requires a destination and at least one
source and rejects self-merges. `repos.conf` is not updated automatically.
`$TASK` resolves from the environment or PATH like every other command.

### `drain pr list [--json]`

List open pull requests across all configured repos whose body references
a task UUID (created by drain workers via the git workflow). Shows repo,
PR number, title, URL, and linked task UUID. Use `--json` for JSON output. Discovery requires authenticated `gh`, a
GitHub `origin`, and a directory-valued `.git` (linked worktrees are skipped).
It matches `Task <full-uuid>` in the body, not any UUID, and does not prove
worker authorship. Gitea PRs are not scanned; `gh` default result limits apply.
Missing CLI/auth/query failures can produce an empty list. Also surfaced in
`drain status` under **PENDING APPROVAL**.

### `drain docs`

The extended operator manual: pickup rules, tags, retrying failed tasks,
the agent prompt contract, stopping, and safety dials. Read this before
your first `drain start`.

## `task-drain.sh` direct modes

Normally launched via `drain`, but runnable directly:

```bash
bash /absolute/path/to/task-drain/task-drain.sh [run|status|history|pr-list|watch|workers|autoscale]
```

| Mode | Behavior |
|---|---|
| `run` (default) | Run one worker: loop until the queue is empty (or STOP), then exit |
| `autoscale` | Run the autoscale supervisor daemon |
| `status` | One-shot queue dashboard (same renderer as `drain status`) |
| `history` | One-shot history view; accepts `--limit N` |
| `pr-list` | PR discovery; accepts `--json` |
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
| `logs/` | Worker logs and `autoscale.log` |
| `taskchampion-data/` | Optional installer-managed sync-server data; preserve during cleanup |

## Operational caveats

- `drain start` reports spawned PIDs before worker startup checks complete.
  Read logs to confirm startup. Repeated starts add workers; 8 is not a global cap.
- `drain autoscale` does not clear STOP. Use `drain resume` first if a previous
  stop left it set. `drain start` does clear it, potentially allowing other
  local workers to resume pickup too.
- Default `drain stop` / `all` sets STOP and stops the autoscaler even when
  no workers exist. `drain stop N` does neither; use `drain autoscale-stop`
  explicitly for the supervisor in that case.
- Use `--min N` and `--max N` with spaces. The current equals-form parser
  fails to advance its argument loop (`--min=N` / `--max=N`).
- Worker counting/stopping is local and not isolated by project. A supervisor
  can count or stop workers launched for another project.
- History retention is applied on writes. A larger display `--limit` cannot
  recover entries already pruned. Set `DRAIN_HISTORY_LIMIT` on workers too.
- Match the dashboard's `DRAIN_AUTONOMOUS` environment to the running pool;
  it is not inferred from workers. Watch refreshes do not continually sync.
- The embedded `drain docs`/help text has some older claims. These Markdown
  references describe the implementation's limits; see [architecture](architecture.md).
