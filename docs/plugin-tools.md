# Plugin tool reference

The `plugin/` directory exposes the Taskwarrior shared-pool lifecycle as 22
native agent tools — as an OpenCode plugin (`task_*` namespaced tools) and
as the `taskwarrior-mcp` MCP server for Claude Code, Cursor, OpenCode, and
Codex. Install: [plugin/README.md](../plugin/README.md).

Data tools sync before reads and around writes unless `autoSync` is
disabled (`TASK_AUTO_SYNC=0`). `sync` always syncs, `doctor` attempts sync
as a diagnostic, and `setup` only generates/writes a script. A sync error
fails the call, but prior local writes are not rolled back. Tasks are always referenced by full UUID; numeric IDs
are replica-local and rejected.

## Lifecycle guards

Lifecycle tools check `status:pending`; `modify`, `annotate`,
`add_dependency`, and decision annotations do not enforce that guard.
`force` is available only on claim/start/stop/approve/complete/auto.
These are workflow checks, not authenticated authorization.

| Tool | Guards |
|---|---|
| `claim` | Refuses tasks already in review (`ready-for-review`/`review`) or already claimed, including by the same actor; `force` bypasses the claim/status checks but never the in-review rejection. Tasks owned by an active drain worker (`drain-claimed`) are additionally protected: `force:true` alone is rejected; an explicit `overrideDrainClaim:true` plus a non-empty `overrideReason` is required, and the override is recorded as a `[actor] drain-override:` annotation for audit. |
| `start` | Refuses already-started tasks. Actively drain-worked tasks (`drain-claimed` + started) require `overrideDrainClaim:true` with `overrideReason` instead of `force` alone. |
| `complete` | Requires `+approved` (use `approve` first); `force:true` bypasses the approval check but requires a `note` |
| `approve` | Requires `+ready-for-review` |

Custom UDA writes are not supported by these schemas/helpers. This reflects
the original shared pool configuration, not a claim that all Taskwarrior
installations have no UDAs; undefined UDA-style arguments can be interpreted
as description text. Ownership and
evidence travel in tags + annotations. Underscore tag spellings
(`ready_for_review`) are normalized to the canonical hyphenated tags.

## Tools

### `sync`
Synchronize the local replica with the TaskChampion server. Runs
automatically around the other tools.

### `add`
Create a task. Check `list` for duplicates first.
Inputs: `description` (required), `project`, `priority` (`H`/`M`/`L`), `due`,
`scheduled`, `wait`, `until`, `recur`, `tags`, `depends` (UUIDs),
`annotations` (recorded as `[actor] note:` annotations), `actor`.
Returns the created task, resolved to its UUID.

### `list`
Structured task listing. Inputs: `status`
(`pending`/`completed`/`deleted`/`waiting`/`recurring`/`all`, default
`pending`), `project`, `tags` (must carry all), `exclude_tags` (carry none),
`limit` (default 50, max 500). Hyphenated tags are filtered client-side —
the CLI mis-parses them in filter expressions.

### `get`
One task by full UUID, including annotations and tags.

### `modify`
Change description, project, priority, dates, or tags of one task.
Inputs: `uuid` (required), `description`, `project`, `priority`, `due`,
`scheduled`, `wait`, `until`, `recur`, `add_tags`, `remove_tags`, `note`
(recorded as an annotation), `actor`.

### `annotate`
Add a structured `[actor] action: detail` annotation.
Inputs: `uuid`, `actor`, `action`, `detail` (all required).

### `add_dependency`
Record a `depends` edge: task `uuid` is blocked by `depends_on` (both UUIDs required).

### `claim`
Claim a task for `actor` before starting work (UUID + actor required,
`force` to steal an existing claim). Fails if the task is in review or
already claimed, including by the same actor. `force` does not allow
claiming a task in review.

### `release`
Release a claim for reassignment. Stops active work first if the task was
started. Inputs: `uuid`, `actor` (required), `reason`.

### `start` / `stop`
Mark a task as actively being worked (`task start`) / pause work without
completing it. Both take `uuid`, `actor` (required); `start` takes `force`,
`stop` takes `note` and `force`. `stop` refuses tasks that were never
started (unless `force`).

### `submit_for_review`
Move a worked task to `+ready-for-review` with evidence (stops active work,
removes the claim). Never completes the task. Inputs: `uuid`, `actor`,
`evidence` (required), `reviewer` (recorded in the annotation).

### `approve`
Approve a `ready-for-review` task: `-ready-for-review -review +approved`,
with an annotation. Inputs: `uuid`, `actor` (required), `note`, `force`.

### `complete`
`task done`. Requires `+approved` (or `force:true` with a `note`),
with a completion annotation. Inputs: `uuid`, `actor` (required), `note`,
`force`.

### `agent_queue`
Pending actionable tasks for one actor: claimed by or annotated by them,
not yet in review. Inputs: `actor` (required), `limit` (default 50, max 500).

### `review_queue`
Pending tasks waiting for review (`+ready-for-review`). Input: `limit`.

### `blocked_tasks`
Pending tasks with the stored lowercase `blocked` tag. This does not compute
unmet `depends` edges or query Taskwarrior's virtual `BLOCKED` tag. Input:
`limit` (default 50, clamped to 1–500).

### `record_decision`
Record a decision two ways: annotate an existing task (`taskUuid`), or
create a new open `DECISION: <title>` task tagged `+decision` (`title` +
optional `project`/`tags` required in that case). Inputs: `actor`
(optional, defaults to `opencode`), `decision` (required), `taskUuid`, `title`, `project`, `tags`.

### `overview`
Session-start board: pending count, blocked / ready-for-review / claimed
counts (client-side tag filtering), project and tag listings.

### `doctor`
Environment check: task binary present, TaskChampion sync reachable, plus
platform-specific install instructions when something is missing.

### `setup`
Generate a platform-specific shell script that installs Taskwarrior. Its
sync client is built into 3.x; a shared remote pool still requires a separate
sync server. This tool neither executes the generated script nor provisions
the server.
Inputs: `includeVerify` (default true), `write` (save to a file instead of
returning text), `overwrite` (required to replace an existing file),
`outputPath` (restricted to the current directory; symlinked working
directory and parent paths are resolved before the containment check, and a
symlink at the final path component is refused). `includeSyncService`
is accepted for compatibility but deprecated. `write:true` alone fails on
an existing file; no confirmation is built into the handler.

### `auto`
One-call workflow: sync → find/claim/start next task, or
create+claim+start a new task from `description`. Inputs: `actor`
(default `opencode`),
`description`, `project`, `priority`, `tags`, `force`.

## Configuration

Plugin options or environment:

| Option | Env | Default |
|---|---|---|
| `taskBin` | `TASK_BIN` | `/opt/homebrew/bin/task` if it exists, else `task` on PATH |
| `taskrc` | `TASKRC` | default `~/.taskrc` pool |
| `autoSync` | `TASK_AUTO_SYNC=0` disables | `true` |

## Source layout

- `src/task.mjs` — testable logic (validation, guards, arg builders). Tested by `npm test`; avoid relying on a fixed test count. See [development](development.md).
- `src/tools.ts` — the 22 tool descriptors (name, schema, handler) defined exactly once.
- `src/index.ts` — thin OpenCode plugin wrapper.
- `src/mcp-server.ts` — MCP server entry point (`taskwarrior-mcp` binary).
- `tests/integration.test.mjs` — exercises helpers and manually reproduced lifecycle operations against real Taskwarrior and sync. It does not verify every tool handler or MCP transport. Run only against an isolated scratch profile/pool; it creates and deletes real tasks.

## Selection, responses, and limits

`agent_queue` excludes `ready-for-review`, `review`, and `approved`, then
matches the latest claim actor or any annotation starting with `[actor]`.
It can include previously released tasks and is not an ownership authority.
`auto` first takes the first actor-associated pending task, otherwise the
first unclaimed pending task without stored blocked/review/approved tags.
It does not sort by urgency, honor worker `auto`/`noauto`/`drain-failed`
filters, or apply its `project`, `priority`, and `tags` inputs to selection
(those inputs apply when creating a task). It does not independently reject
unmet dependencies or tasks already active under another workflow.

`start` does not require `claimed`; `stop` retains the claim; `release`
removes `claimed` and stops work but does not verify the caller owns it.
`complete` requires `+approved` (or `force:true` with a `note`)
and does not run tests or check evidence. `record_decision` does not write
`docs/DECISIONS.md`; promote durable decisions there explicitly.

MCP names are `task_<name>`; OpenCode registers the `task` namespace with
codemode enabled. Successful responses are JSON serialized into text.
Most mutations return the task object directly; `get` returns `{task}`;
list/queue tools return `{tasks, count, total_matching}`; `sync` returns
`{ok, output}`. `auto` returns `{task, action}` with `created_and_started`,
`claimed_and_started`, `started`, or `none_found` (null task). Handler errors
reject the call; there is no rollback or retry transaction. Re-read state
before repeating a mutation after an error, especially creation.

Example MCP tool arguments (replace UUID and actor):

```json
{"uuid":"11111111-1111-4111-8111-111111111111","actor":"engineer"}
```

Use these for `task_claim` then `task_start`; submit with `evidence`, then
approve and complete as your team's policy requires. Do not assume tool
availability or caller-provided actor names enforce a human approval gate.

Plugin options take precedence over environment variables. Taskwarrior
inherits the process environment, including its own profile/data settings.
The MCP adapter exposes only environment configuration and stdio transport.
