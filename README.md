# task-drain

Autonomous <a href="https://taskwarrior.org/" target="_blank" rel="noopener noreferrer">Taskwarrior</a> queue workers powered by
your AI coding agent. Each worker loops: sync → pick the highest-urgency
eligible task → claim it → hand it to the agent non-interactively →
verify → repeat until the queue is empty, then exit.

Supported harnesses (set with `DRAIN_AGENT`): <a href="https://opencode.ai/" target="_blank" rel="noopener noreferrer">OpenCode</a>
(default), <a href="https://docs.anthropic.com/en/docs/claude-code" target="_blank" rel="noopener noreferrer">Claude Code</a>,
<a href="https://github.com/openai/codex" target="_blank" rel="noopener noreferrer">Codex</a>.

Pickup is **opt-out** by default: any pending task is eligible unless it is
active, waiting, blocked, or tagged `noauto` / `drain-failed`.
Use `--autonomous` (or `DRAIN_AUTONOMOUS=1`) for **opt-in** pickup — only
tasks tagged `+auto` are eligible, and the autoscaler is launched to pick up
new tickets.

## Two operating modes

**1. Task layer only — no workers.** The bundled [`plugin/`](plugin/README.md)
gives any agent session 22 Taskwarrior tools (`task_sync`, `task_claim`,
`task_add`, …) as an OpenCode plugin or an MCP server for Claude Code,
Cursor, and Codex. Your agent does claim → work → review → complete with
you in the loop. Nothing runs unless you ask it to.

**2. Autonomous workers.** `drain start` spins up background workers that
grind through the queue on their own, with a live dashboard (`drain status`
/ `-w` / `--workers`), an autoscaler, per-task wall clocks, and a real
kill switch.

See [docs/operating-modes.md](docs/operating-modes.md) for the full
comparison, and the safety rails that make Mode 2 sane
(opt-in `--dangerously-skip-permissions`, `noauto` opt-out / `auto` opt-in,
`drain-failed` parking, stale-claim release, no telemetry).

## Quick start

```bash
git clone https://github.com/ncdlabs/task-drain.git
cd task-drain
./install.sh          # deps, sync server, symlinks into ~/bin, plugin build
drain docs            # pickup rules, tags, kill switch — read this first
drain projects        # check your project → repo mappings
drain autoscale        # start the autoscaler (scales workers to queue depth)
```

Full instructions: [docs/installation.md](docs/installation.md).

## Usage

```bash
drain start 2                  # start 2 background workers (default)
drain start 4 myproject        # 4 workers, one project only
drain start 2 --failed         # retry drain-failed tasks (one retry each)
drain start 2 --persist        # workers wait for new jobs after queue empties
drain start --autonomous       # opt-in mode: only +auto tasks; launches autoscaler
drain status                   # queue dashboard: workers, counts, failed list
drain status -w                # live dashboard (q quits)
drain status --workers         # live per-worker view
drain status --verbose         # show full task lists instead of capped summary
drain logs [-f]                # tail worker logs
drain unfail [project]         # remove drain-failed tag, return to regular queue
drain stop                     # graceful stop (finish current task, then exit)
drain stop --force             # immediate stop (TERM mid-task, like drain kill)
drain kill                     # immediate stop (claims released; autoscaler stopped too)
drain autoscale [project]      # supervisor daemon: auto-scale workers to queue depth
drain autoscale-stop           # stop the autoscaler (workers keep running)
drain resume                   # clear the STOP file (doesn't start workers)
drain pr list [--json]         # list open PRs from drain agents (PENDING APPROVAL)
drain history [--limit N]      # show last N processed tasks (default 20)
drain projects merge <dst> <src...>  # merge source projects into destination
```

The kill switch also works by hand: `touch ~/.task-drain/STOP` stops workers
gracefully; `drain kill` stops them immediately.

Complete command reference: [docs/cli-reference.md](docs/cli-reference.md).

## Tags

| Tag | Meaning |
|-----|---------|
| `noauto` | Opt out of worker pickup. Workers never touch these. |
| `auto` | Opt in to worker pickup in autonomous mode (`--autonomous` / `DRAIN_AUTONOMOUS=1`). Only these tasks are eligible. |
| `drain-failed` | A worker tried this task and couldn't complete it. Re-queue with `task <uuid> modify -drain-failed`, or retry the set with `drain start N --failed`. |
| `drain-claimed` | In-flight marker while a worker owns a task. Auto-released after 4h if the worker dies. |

## Configuration

Environment variables (export before `drain start`, or edit the top of
`task-drain.sh`). The important ones:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DRAIN_AGENT` | `opencode` | `opencode` \| `claude` \| `codex` |
| `DRAIN_MODEL` | `opencode-go/longcat-2.5-preview-free` | Model for worker runs |
| `DRAIN_SKIP_PERMISSIONS` | `0` | `1` adds `--dangerously-skip-permissions` — the main risk dial, opt-in only |
| `DRAIN_AUTONOMOUS` | `0` | `1` = opt-in pickup (only `+auto` tasks eligible); also launches the autoscaler |
| `DRAIN_OWNER` | `the project owner` | Human authority for design/security/product decisions in the worker prompt |
| `TASK_TIMEOUT_SEC` | `14400` | Per-task wall clock (needs `gtimeout`) |
| `STALE_AFTER_SEC` | `14400` | Release worker claims older than this |

Everything: [docs/configuration.md](docs/configuration.md) (all variables,
tags, `repos.conf`, state files).

## Documentation

- [docs/installation.md](docs/installation.md) — prerequisites, installer knobs, manual install, sync server setup, plugin install, verification
- [docs/operating-modes.md](docs/operating-modes.md) — the two modes, when to use which, safety rails
- [docs/cli-reference.md](docs/cli-reference.md) — every `drain` command and `task-drain.sh` mode
- [docs/plugin-tools.md](docs/plugin-tools.md) — all 22 plugin tools, guards, configuration
- [docs/configuration.md](docs/configuration.md) — environment variables, tags, project → repo mapping
- [docs/uninstall.md](docs/uninstall.md) — removal: stop, unlink, clean state, unconfigure plugin, server teardown
- [plugin/README.md](plugin/README.md) — plugin install and MCP client setup

## How the worker prompt works

Every worker hands its task to the configured agent harness with a prompt
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

Code changes go on feature branches; the agent pushes the branch and opens a
PR, leaving it unmerged for human review.

## License

MIT — see [LICENSE](LICENSE).
