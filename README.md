# task-drain

Autonomous <a href="https://taskwarrior.org/" target="_blank" rel="noopener noreferrer">Taskwarrior</a> queue workers powered by
your AI coding agent. Each worker loops: sync → pick the highest-urgency
eligible task → claim it → hand it to the agent non-interactively →
check task completion status → repeat until the queue is empty, then exit.

Supported harnesses (set with `DRAIN_AGENT`): <a href="https://opencode.ai/" target="_blank" rel="noopener noreferrer">OpenCode</a>
(default), <a href="https://docs.anthropic.com/en/docs/claude-code" target="_blank" rel="noopener noreferrer">Claude Code</a>,
<a href="https://github.com/openai/codex" target="_blank" rel="noopener noreferrer">Codex</a>.

Pickup is **opt-out** by default: any pending task is eligible unless it is
active, waiting, blocked, or tagged `noauto` / `drain-failed`.
Use `--autonomous` (or `DRAIN_AUTONOMOUS=1`) for **opt-in** pickup — only
tasks tagged `+auto` are eligible. The `--autonomous` flag also launches the
autoscaler; the environment variable alone only changes eligibility. In this
mode `noauto` is not excluded: remove `auto` to withhold a task.

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
comparison, and the operational limits of Mode 2
(opt-in `--dangerously-skip-permissions`, `noauto` opt-out / `auto` opt-in,
`drain-failed` parking, stale-claim release, no telemetry).

## Quick start

```bash
git clone https://github.com/ncdlabs/task-drain.git
cd task-drain
./install.sh          # deps, sync server, symlinks into ~/bin, plugin build
drain docs            # pickup rules, tags, kill switch — read this first
drain projects        # check your project → repo mappings
DRAIN_AUTONOMOUS=1 drain status myproject  # inspect the opt-in queue
# After configuring the agent and tagging a reviewed task +auto:
DRAIN_AUTONOMOUS=1 drain start 1 myproject  # one worker, no autoscaler
```

Requires Taskwarrior 3.x with working sync, Bash, jq, and an authenticated
agent CLI. The plugin requires Node.js 20+; development tests use Node.js 22+.
Read the [installation guide](docs/installation.md) before running the
installer against an existing Taskwarrior profile.

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
| `noauto` | Excludes default-mode pickup; autonomous mode checks `auto` instead. |
| `auto` | Opt in to worker pickup in autonomous mode (`--autonomous` / `DRAIN_AUTONOMOUS=1`). Only these tasks are eligible. |
| `drain-failed` | A worker tried this task and couldn't complete it. Re-queue with `task <uuid> modify -drain-failed`, or retry the set with `drain start N --failed`. |
| `drain-claimed` | In-flight marker while a worker owns a task. Eligible for release by another running worker after 4h of active time; worker liveness is not checked. |

## Configuration

Environment variables (export before `drain start`). The important ones:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DRAIN_AGENT` | `opencode` | `opencode` \| `claude` \| `codex` |
| `DRAIN_MODEL` | `opencode-go/longcat-2.5-preview-free` | Model for worker runs |
| `DRAIN_SKIP_PERMISSIONS` | `0` | `1` adds `--dangerously-skip-permissions` to OpenCode only |
| `DRAIN_AUTONOMOUS` | `0` | `1` = opt-in pickup; only the CLI `--autonomous` flag also starts the autoscaler |
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
- [docs/architecture.md](docs/architecture.md) — worker lifecycle, concurrency, enforcement boundaries
- [docs/development.md](docs/development.md) — source map, tests, build, contribution workflow
- [docs/troubleshooting.md](docs/troubleshooting.md) — diagnosis and recovery
- [docs/DECISIONS.md](docs/DECISIONS.md) — historical decisions and current qualifications
- [plugin/README.md](plugin/README.md) — plugin install and MCP client setup

## How the worker prompt works

Every worker hands its task to the configured agent harness with a prompt
requesting:

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

The prompt instructs the agent to use a feature branch, push it, and open a
PR for human review. The shell only checks whether Taskwarrior reports
`completed`; it does not independently validate tests, commits, or PRs.
Workers share mapped checkouts, and claims are not atomic. See
[architecture and limits](docs/architecture.md) before running concurrent workers.

## Development

```bash
(cd plugin && npm ci && npm run typecheck && npm test && npm run build)
bats tests/task-drain.bats
bash -n drain task-drain.sh install.sh lib/display.sh lib/worker-detect.sh
```

Use Node.js 22+ and install Bats and jq for these checks. Live integration
tests require a separate scratch Taskwarrior profile and sync pool; see
[development](docs/development.md).

## License

MIT — see [LICENSE](LICENSE).
