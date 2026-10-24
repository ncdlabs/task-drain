# Architecture and execution boundaries

## Components

| Component | Responsibility |
|---|---|
| `drain` | CLI parsing, background launch, stop controls, project listing/merge |
| `task-drain.sh` | Queue selection, claims, agent prompt/invocation, outcome recording, dashboard, autoscaling |
| `lib/worker-detect.sh` | Host process discovery and worker identity parsing |
| `lib/display.sh` | Terminal formatting shared by dashboards |
| `plugin/src/task.mjs` | Taskwarrior subprocess adapter, validation, lifecycle guards |
| `plugin/src/tools.ts` | Shared definitions of 22 tools |
| `plugin/src/index.ts` | OpenCode v2 plugin adapter |
| `plugin/src/mcp-server.ts` | MCP stdio adapter exposing `task_*` tools |
| `install.sh` | Dependency setup, optional sync container, script symlinks, plugin build |

Taskwarrior owns task data. TaskChampion synchronizes replicas. The plugin
and shell workers invoke Taskwarrior separately; neither calls the other.
Worker state under `~/.task-drain/` belongs to the OS user and is shared
across projects and Taskwarrior profiles.

```mermaid
flowchart LR
    CLI[drain CLI] --> Supervisor[Optional autoscaler]
    CLI --> Worker[Shell workers]
    Supervisor --> Worker
    Worker --> Agent[Agent CLI in mapped checkout]
    Worker --> Task[Local Taskwarrior replica]
    Agent --> Task
    Client[OpenCode or MCP client] --> Plugin[Plugin tools]
    Plugin --> Task
    Task <--> Server[TaskChampion sync server]
```

## Worker lifecycle

1. Check executable dependencies and STOP state; abort if initial sync fails.
2. In retry mode, snapshot eligible failed-task UUIDs into a per-worker file.
3. Before each selection, release active `drain-claimed` tasks older than
   `STALE_AFTER_SEC` whose recorded local worker PID is dead (`kill -0`
   check). The candidate scan covers all projects but releases only this
   host's claims; it cannot detect death on other hosts or PID reuse.
4. Normal mode exports the eligible set and selects greatest urgency. Retry
   mode consumes its snapshot, rechecking pending, failed, and idle state.
5. Add `drain-claimed`, annotate, start the task, and sync the claim before
   invoking the agent. Failed claim publication skips execution and attempts
   to release the claim.
6. Run one agent in the mapped directory (or HOME if unresolved), with stdin
   closed. A background annotator records progress approximately every 30s.
7. After the agent exits, attempt sync and inspect task status. Success
   requires status `completed` **and** agent exit code 0; otherwise record
   failure, add `drain-failed`, release the claim, and attempt sync. The
   shell runs no acceptance tests and validates no commits or PRs.
8. Repeat; an empty queue causes exit unless `DRAIN_PERSIST=1`. The empty
   path attempts sync but does not reselect before a nonpersistent exit.

The completed path does not explicitly remove `drain-claimed`. History is
a rolling TSV with timestamp, UUID, project, description, result, elapsed
seconds, and worker ID. Concurrent append/prune operations are not locked;
it is an operator convenience, not a durable audit log.

## Enforced behavior versus agent instructions

The shell enforces selection filters, initial/claim sync checks, and a
wall-clock limit **only when `gtimeout` is found**. It does not independently
run acceptance tests, validate evidence, check PR creation, require human
approval, or parse the agent's final `DONE:`/`FAILED:` line.

The prompt asks the agent to verify work, use feature branches, commit, push,
open a PR, and defer owner decisions. These are behavioral instructions,
not authorization controls. Agent permissions, credentials, hooks, and
repository instructions determine what execution can actually do.

There is no blanket offline guarantee: completion sync failures are ignored
before status inspection, and the autoscaler uses local state on sync failure.
The plugin fails a tool call on sync errors, but a failed post-write sync
can leave local mutations applied. None of these operations is transactional.

## Concurrency and isolation

- Selection and claim are separate operations without a distributed lock or
  compare-and-swap. Two workers can execute the same task. A published claim
  reduces this window but does not provide exactly-once execution.
- Workers use the mapped checkout directly and do not create worktrees.
  Drain workers serialize Git operations per repository with a host-local
  lock, so two drain workers never run agents in the same checkout
  concurrently. Plugin-driven or interactive work in the same checkout is
  unsynchronized: different tasks can still change the same working tree
  concurrently. Use isolated mappings and tasks deliberately.
- Stale reclamation can release a still-running task, especially when the
  task timeout is disabled or longer than the stale threshold.
- Retry snapshots and consumption are per worker. With multiple workers,
  the same task can be retried more than once across the pool.
- Stop controls are host-local. They do not stop workers on other machines
  sharing the same TaskChampion pool. TERM cleanup is best-effort; hard kills,
  detached descendants, or sync failures can leave work or claims behind.
- The autoscaler counts host processes matching the script path whose recorded
  project filter matches its own (file-backed worker registry), not just
  workers for its project. Its one PID file is shared across project runs:
  only one supervisor runs per host, and a second `drain autoscale` (any
  project) is rejected while it is alive. Liveness is verified by PID plus
  command-line identity, so PID reuse by an unrelated process can neither
  block startup nor cause a kill; a transient `autoscale.starting` mutex
  serializes concurrent launches.

## Plugin and worker coexistence

Plugin ownership is `claimed` plus `[actor] claimed:` annotations; workers
use `drain-claimed` plus `claimed by drain-...` annotations. They are different
protocols. The worker eligibility filter excludes `claimed`,
`drain-claimed`, `ready-for-review`, `review`, and `approved` tags in both
pickup modes, so shell workers do not pick up plugin-owned or in-review tasks.

For an interactive task withheld from both shell pickup modes, add `noauto`
and remove `auto` before releasing active work. Plugin `task_auto` does not
honor those worker tags. Explicitly select UUIDs when mixing workflows.

Plugin actors are caller-provided annotation labels, not authenticated
identities. Approval tools do not establish that a human approved anything.
`task_complete` requires `+approved` (use `approve` first); `force:true`
bypasses the approval check but requires a `note`. See [tool semantics](plugin-tools.md).

## Data and network access

Task descriptions, annotations, and repository context are given to the
configured agent and may be sent to its model provider. Taskwarrior contacts
the configured sync server; PR discovery contacts GitHub via `gh`; optional
error webhooks receive diagnostic details. There is no separate analytics
collector in this repository. Logs and task annotations can contain sensitive
context; retain and share them accordingly.
