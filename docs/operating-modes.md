# Operating modes

task-drain is two systems that share one Taskwarrior pool. Run either one
alone, or both together.

## Mode 1 — Task layer only (no workers)

Install the [plugin](../plugin/README.md) (OpenCode plugin or MCP server)
and any agent session gets 22 native Taskwarrior tools: `task_sync`,
`task_add`, `task_list`, `task_claim`, `task_start`, `task_submit_for_review`,
`task_approve`, `task_complete`, and more
([full tool reference](plugin-tools.md)).

In this mode **you stay in the loop**. Your agent performs the Taskwarrior
session duties — sync before/after operations, UUID-first references,
claim → work → review → approve → complete, decision recording — without
hand-rolled `task` shell invocations. Nothing runs unless you ask it to.

Use this mode when:

- you work interactively with a coding agent and want it to manage tasks properly,
- you want the discipline (sync hygiene, claim guards, review gates) without autonomy,
- you're evaluating the system before trusting workers.

The `drain` CLI's read-only commands (`drain status`, `drain history`,
`drain projects`) are also useful here as a human dashboard over the queue —
they never start agents.

## Mode 2 — Autonomous workers

`drain start` (or `drain autoscale`) launches background workers. Each worker
loops:

```
sync → release stale claims → pick highest-urgency eligible task
     → claim it → run the agent on it → verify → repeat until empty
```

**Eligibility** is opt-out by default: any task is picked up unless it is
already active, waiting, blocked, or tagged `noauto` / `drain-failed`.
With `--autonomous` (or `DRAIN_AUTONOMOUS=1`), eligibility is opt-in: only
tasks tagged `+auto` are picked up, and the autoscaler is launched to pick
up new tickets as they are tagged. Details in `drain docs` and
[Configuration](configuration.md#tags).

The agent runs under a prompt that enforces three non-negotiables:

- **Discipline** — Taskwarrior is the only system of record; sync at session
  start, after every change, and at session end; never work offline.
- **Authority** — design, security, product, and public-facing decisions
  belong to the human (`DRAIN_OWNER`). Anything needing judgment gets
  annotated and failed, never decided.
- **Completion contract** — verify for real (build, tests, acceptance
  criteria) or mark failed. Partial work is never marked done.

Code changes go on feature branches; the agent pushes the branch and opens
a PR, leaving it unmerged for human review. Use this mode when you have a
queue of well-specified tasks and want the machine to grind through them
while you do something else.

### Safety rails (both modes, critical for Mode 2)

- **Kill switch** — `drain stop` is graceful (finish the current task, then
  exit); `drain kill` / `drain stop --force` is immediate, with in-flight
  tasks released back to pending, and also stops the autoscaler so nothing
  respawns. By hand: `touch ~/.task-drain/STOP`.
- **No silent retries** — a failed attempt tags the task `drain-failed`;
  workers never pick those up on their own. Re-queue explicitly
  (`task <uuid> modify -drain-failed`) or retry the set once each with
  `drain start N --failed`.
- **`--dangerously-skip-permissions` is opt-in** (`DRAIN_SKIP_PERMISSIONS=1`).
  Without it, unattended runs stall on the first approval prompt; with it,
  the agent can edit, run, and push without asking. Only enable it if you
  trust the worker to operate without human approval.
- **Stale claims auto-release** — a worker that dies mid-task has its claim
  released after `STALE_AFTER_SEC` (default 4h). Only worker claims are ever
  released; your interactive sessions' active tasks are never touched.
- **No telemetry.** Error webhooks (`DRAIN_ERROR_WEBHOOK`) are opt-in.

## Choosing

| | Mode 1: task layer | Mode 2: workers |
|---|---|---|
| Agent acts without you | No | Yes |
| Needs an agent CLI installed | No | Yes |
| Needs `DRAIN_SKIP_PERMISSIONS=1` to be useful | N/A | Recommended for unattended runs |
| Risk profile | Same as your normal agent session | Autonomous shell access — use the kill switch, `noauto` / `auto`, and review PRs |
| Start with | `plugin/` install | `drain start 2` |

Most people start with Mode 1, then turn on workers for a well-specified
project once they trust the loop.
