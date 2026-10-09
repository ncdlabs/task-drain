# task-drain

Autonomous [Taskwarrior](https://taskwarrior.org/) queue workers powered by
[OpenCode](https://opencode.ai/). Each worker loops: sync → pick the
highest-urgency eligible task → claim it → run `opencode run` on it non-
interactively → verify → repeat until the queue is empty, then exit.

Pickup is **opt-out**: any pending task is eligible unless it is active,
waiting, blocked, or tagged `noauto` / `drain-failed`.

## Prerequisites

- **Taskwarrior 3.x** with [TaskChampion sync](https://github.com/GothenburgBitFactory/taskchampion)
  configured against a sync server. This is a hard requirement — workers abort
  if the initial sync fails ("never work offline"). The shared sync pool is
  what makes multi-machine workers possible.
- **A TaskChampion sync server.** Self-host
  [taskchampion-sync-server](https://github.com/GothenburgBitFactory/taskchampion-sync-server)
  (Rust; `cargo install --path .` from that repo, or use their Docker image),
  then point Taskwarrior at it:
  ```
  task config sync.server.url https://your-sync-server.example
  task config sync.server.client_id $(uuidgen)
  ```
  Each machine needs its own `client_id` and its own `data.location`.
  There is currently no public hosted TaskChampion sync service.
- **OpenCode CLI v2** (`opencode`) on PATH — workers invoke `opencode run`
  with `--standalone --dangerously-skip-permissions`
- **jq** (queue queries are parsed with `jq`)
- **gtimeout** (optional, from coreutils — enables the per-task wall clock;
  without it tasks run unbounded)
- **bash 4+**
- Primarily tested on **macOS** (Homebrew). Linux works if `task`,
  `opencode`, and `jq` are on PATH — see [Configuration](#configuration)
  for the paths you'll need to override.

## Installation

```bash
git clone https://github.com/ncdlabs/task-drain.git
cd task-drain
./install.sh
```

This symlinks (not copies) `task-drain.sh` and `drain` into `~/bin/`,
so `git pull` in the repo updates your install. Set `PREFIX=/usr/local`
to install into `/usr/local/bin` instead.

The installer also clones and builds the
[opencode-tasks](https://github.com/ncdlabs/opencode-tasks) plugin
into `~/git/opencode-tasks` (override with `PLUGIN_DIR=`, skip with
`SKIP_PLUGIN=1`). Add its path to your `opencode.json` under `"plugin"`
to give agents native Taskwarrior tools. The drain workers don't require
it -- they use direct `task` shell commands -- but it's useful for
interactive sessions.

Both scripts are executable; invoke `drain` directly (no `bash` prefix needed).

## Usage

```bash
drain start 2                  # start 2 background workers (default)
drain start 4 myproject        # 4 workers, one project only
drain start 2 --failed         # retry drain-failed tasks (one retry each)
drain status                   # queue dashboard: workers, counts, failed list
drain status -w                # live dashboard (q quits)
drain status --workers         # live per-worker view
drain logs [-f]                # tail worker logs
drain stop                     # graceful stop (finish current task, then exit)
drain kill                     # immediate stop (claims released to pending)
drain resume                   # clear the STOP file (doesn't start workers)
drain docs                     # pickup rules, tags, kill switch, safety dials
```

The kill switch also works by hand: `touch ~/.task-drain/STOP` stops workers
gracefully; `pkill -TERM -f task-drain.sh` stops them immediately.

## Tags

| Tag | Meaning |
|-----|---------|
| `noauto` | Opt out of worker pickup. Workers never touch these. |
| `drain-failed` | A worker tried this task and couldn't complete it. Regular workers skip it; clear with `task <uuid> modify -drain-failed` to re-queue, or retry the whole set with `drain start N --failed`. |
| `drain-claimed` | In-flight marker set while a worker owns a task. Auto-released after 4h if the worker dies (only worker claims are ever released — your interactive sessions' active tasks are never touched). |

Workers never retry `drain-failed` on their own, and `--failed` runs retry
each failed task at most once, so nothing loops forever.

## Configuration

Environment variables (export them before `drain start`, or edit the top of
`task-drain.sh`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `TASK` | `task` on PATH, else `/opt/homebrew/bin/task` | Taskwarrior binary |
| `OPENCODE_BIN` | `opencode` | OpenCode binary |
| `DRAIN_MODEL` | `opencode-go/longcat-2.5-preview-free` | Model for worker runs |
| `GIT_ROOT` | `$HOME/git` | Where your repos live |
| `DRAIN_OWNER` | `the project owner` | Human authority named in the worker prompt for design/security/product decisions (workers must annotate and fail instead of deciding) |
| `PROJECT_FILTER` | (unset) | Limit one worker run to a single project |
| `STALE_AFTER_SEC` | `14400` (4h) | Release worker claims older than this |
| `TASK_TIMEOUT_SEC` | `14400` (4h) | Per-task wall clock (needs `gtimeout`) |
| `DRAIN_RETRY_FAILED` | `0` | `1` = reprocess `drain-failed` instead of the regular queue (normally set via `drain start --failed`) |

**Project → repo mapping.** `repo_for_project()` in `task-drain.sh` maps
Taskwarrior project names to checkout paths (used as the worker's working
directory). The built-in table is a set of examples — **edit it for your
projects**, or add overrides in `~/.task-drain/repos.conf` (one per line,
takes precedence):

```
myproject=$HOME/git/myrepo
other=~/git/other
```

Tasks whose project has no mapping (or whose repo dir doesn't exist) run
with `$HOME` as the working directory.

**Git workflow.** When a task involves code changes, the worker prompt
instructs the agent to: work on a feature branch (never main), commit with
the task UUID referenced, push, and open a PR — leaving it unmerged for
human review. GitHub uses `gh pr create`; other forges use their API with a
`FORGE_TOKEN` env var. If push/PR fails, the task is marked failed, not done.

## How the worker prompt works

Every worker hands its task to `opencode run --standalone` with a prompt
enforcing:

- **Discipline:** Taskwarrior is the only system of record — sync at session
  start, after every change, and at session end; never work offline; never
  change the sync client ID; reference tasks by UUID, never short numeric IDs.
- **Authority:** design, security, product, and public-facing decisions
  belong to the project owner. Anything needing human judgment, missing
  credentials, or irreversible action gets annotated and failed — never
  decided by the agent.
- **Completion contract:** verify for real (build, tests, or the task's own
  acceptance criteria). Only then `task <uuid> done`. Partial or unverified
  work is failed, never marked done.

Two implementation details worth knowing:

- `opencode run` hangs waiting on stdin when not attached to a TTY, so
  workers run it with `--standalone` and stdin redirected from `/dev/null`.
- The working directory is set via subshell `cd` because `opencode run`
  accepts no `--dir` flag.

## Related

- [opencode-tasks](https://github.com/ncdlabs/opencode-tasks) — OpenCode
  plugin exposing Taskwarrior lifecycle tools as native agent tools.
  Optional companion; the drain workers use direct `task` shell commands and
  don't require it.
