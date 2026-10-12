# Plugin tool reference

The `plugin/` directory exposes the Taskwarrior shared-pool lifecycle as 22
native agent tools — as an OpenCode plugin (`task_*` namespaced tools) and
as the `taskwarrior-mcp` MCP server for Claude Code, Cursor, OpenCode, and
Codex. Install: [plugin/README.md](../plugin/README.md).

Every tool syncs before reads and around writes unless `autoSync` is
disabled (`TASK_AUTO_SYNC=0`). A sync failure stops the operation — tools
never work offline. Tasks are always referenced by full UUID; numeric IDs
are replica-local and rejected.

## Lifecycle guards

Most mutating tools require the task to be `status:pending` (completed tasks
are immutable to these tools). `force:true` overrides the guards when you
mean it.

| Tool | Guards |
|---|---|
| `claim` | Refuses tasks already in review (`ready-for-review`/`review`) or already claimed by someone else |
| `start` | Refuses already-started tasks |
| `complete` | Requires `+approved` or `+ready-for-review` |
| `approve` | Requires `+ready-for-review` |

Custom UDAs are refused outright: the shared pool defines none, and the CLI
would silently rewrite the description instead of failing. Ownership and
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
already claimed by someone else.

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
`task done`. Requires `+approved` or `+ready-for-review` (or `force`),
with a completion annotation. Inputs: `uuid`, `actor` (required), `note`,
`force`.

### `agent_queue`
Pending actionable tasks for one actor: claimed by or annotated by them,
not yet in review. Inputs: `actor` (required), `limit` (default 50, max 500).

### `review_queue`
Pending tasks waiting for review (`+ready-for-review`). Input: `limit`.

### `blocked_tasks`
Pending blocked tasks. Input: `limit`.

### `record_decision`
Record a decision two ways: annotate an existing task (`taskUuid`), or
create a new open `DECISION: <title>` task tagged `+decision` (`title` +
optional `project`/`tags` required in that case). Inputs: `actor`
(required), `decision` (required), `taskUuid`, `title`, `project`, `tags`.

### `overview`
Session-start board: pending count, blocked / ready-for-review / claimed
counts (client-side tag filtering), project and tag listings.

### `doctor`
Environment check: task binary present, TaskChampion sync reachable, plus
platform-specific install instructions when something is missing.

### `setup`
Generate a platform-specific shell script that installs taskwarrior
(TaskChampion sync is built into 3.x — there is no separate service).
Inputs: `includeVerify` (default true), `write` (save to a file instead of
returning text), `outputPath` (must stay inside the current directory).

### `auto`
One-call workflow: sync → find/claim/start next task, or
create+claim+start a new task from `description`. Inputs: `actor`,
`description`, `project`, `priority`, `tags`, `force`.

## Configuration

Plugin options or environment:

| Option | Env | Default |
|---|---|---|
| `taskBin` | `TASK_BIN` | `/opt/homebrew/bin/task` if it exists, else `task` on PATH |
| `taskrc` | `TASKRC` | default `~/.taskrc` pool |
| `autoSync` | `TASK_AUTO_SYNC=0` disables | `true` |

## Source layout

- `src/task.mjs` — testable logic (validation, guards, arg builders). Unit-tested with `node --test` (`npm test`, 29 tests, no task binary needed).
- `src/tools.ts` — the 22 tool descriptors (name, schema, handler) defined exactly once.
- `src/index.ts` — thin OpenCode plugin wrapper.
- `src/mcp-server.ts` — MCP server entry point (`taskwarrior-mcp` binary).
- `tests/integration.test.mjs` — exercises the tools against a real `task` binary and sync server (not run by `npm test`; run explicitly against a scratch profile — it creates real tasks).
