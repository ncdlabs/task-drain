# opencode-tasks

TaskChampion/Taskwarrior shared-pool lifecycle as 22 tools
(`task_sync`, `task_add`, `task_claim`, …) — as an OpenCode plugin **and**
as an MCP server (`taskwarrior-mcp`) for Claude Code, Cursor, and Codex.
Install it and any agent session can perform the Taskwarrior session
duties — sync before/after operations, UUID-first references,
claim → work → review → approve → complete, decision recording —
without hand-rolled `task` shell invocations.

Ported from the Phase 6 MCP policy wrapper (`phase6-mcp/policy-server`),
adapted to the live shared pool (bare `/opt/homebrew/bin/task`, default
`~/.taskrc`).

## Install

```sh
git clone https://github.com/ncdlabs/opencode-tasks <path-to-opencode-tasks>
cd <path-to-opencode-tasks>
npm install
npm run build   # compiles src/ -> dist/; the plugin host loads dist/index.js
```

Local path (no publish needed) — in your `opencode.json(c)`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["<path-to-opencode-tasks>"],
}
```

Restart the OpenCode service (`opencode service restart`) or reload so the
plugin activates. Scoped to whatever project/directory the config covers;
global `~/.config/opencode/opencode.json` enables it everywhere.

## MCP server (`taskwarrior-mcp`)

The same 22 tools are exposed over MCP (stdio), so any MCP-capable agent
can use them — Claude Code, Cursor, OpenCode, Codex. The server announces
the claim → work → complete workflow in its instructions, and `SKILL.md`
carries the same rules for clients that load skills.

Run directly with npx (builds from source on first run):

```sh
npx -y github:ncdlabs/opencode-tasks
```

Configure via environment: `TASK_BIN`, `TASKRC`, `TASK_AUTO_SYNC=0`.

### Claude Code

```sh
claude mcp add taskwarrior -- npx -y github:ncdlabs/opencode-tasks
# with env:
claude mcp add taskwarrior -e TASK_BIN=/opt/homebrew/bin/task -- npx -y github:ncdlabs/opencode-tasks
```

### Cursor

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "taskwarrior": {
      "command": "npx",
      "args": ["-y", "github:ncdlabs/opencode-tasks"],
      "env": {
        "TASK_BIN": "/opt/homebrew/bin/task"
      }
    }
  }
}
```

### OpenCode

`opencode.json(c)`:

```jsonc
{
  "mcp": {
    "taskwarrior": {
      "type": "local",
      "command": ["npx", "-y", "github:ncdlabs/opencode-tasks"],
      "environment": {
        "TASK_BIN": "/opt/homebrew/bin/task"
      },
      "enabled": true
    }
  }
}
```

(Or keep using the native plugin below — same tools, no MCP hop.)

### Codex

`~/.codex/config.toml` (MCP support reported in recent Codex CLI versions;
verify with `codex mcp list`):

```toml
[mcp_servers.taskwarrior]
command = "npx"
args = ["-y", "github:ncdlabs/opencode-tasks"]
```

## Configuration

Plugin options (`{ "package": "<path-to-opencode-tasks>", "options": {...} }`)
or environment:

| Option | Env | Default | Meaning |
| --- | --- | --- | --- |
| `taskBin` | `TASK_BIN` | `/opt/homebrew/bin/task` | Task binary |
| `taskrc` | `TASKRC` | shared `~/.taskrc` pool | Alternate profile (e.g. Phase 6) |
| `autoSync` | `TASK_AUTO_SYNC=0` disables | `true` | Sync before reads, around writes |

## Tools

| Tool | Purpose |
| --- | --- |
| `task_sync` | Sync replica with your TaskChampion server (auto-runs around other tools) |
| `task_add` | Create a task (check `task_list` for duplicates first) |
| `task_list` | Structured list: status / project / tags / exclusions / limit |
| `task_get` | One task by full UUID |
| `task_modify` | Description, project, priority, dates, tag add/remove |
| `task_annotate` | Structured `[actor] action: detail` annotation |
| `task_add_dependency` | `depends` edge between two UUIDs |
| `task_claim` | Claim for implementation (refuses review-stage / double-claims) |
| `task_release` | Release a claim for reassignment |
| `task_start` / `task_stop` | Active-work markers |
| `task_submit_for_review` | → `+ready-for-review` with evidence (never completes) |
| `task_approve` | Reviewer approval (`-ready-for-review +approved`) |
| `task_complete` | `task done`; requires `+approved` or `+ready-for-review` (or `force`) |
| `task_agent_queue` | Actor's actionable queue (claimed/annotated, not in review) |
| `task_review_queue` | All `ready-for-review` tasks |
| `task_blocked_tasks` | All `+blocked` tasks |
| `task_record_decision` | Annotate a decision, or create a `DECISION:` `+decision` task |
| `task_overview` | Session-start board: counts + project/tag listings |
| `task_doctor` | Check task binary + sync health; install instructions if missing |
| `task_setup` | Generate (or write) a platform install script for taskwarrior |
| `task_auto` | Claim+start next actionable task, or create+claim+start a new one |

## Live-pool semantics (verified, not assumed)

- **No custom UDAs** on the shared pool. UDA-style writes are silently
  reinterpreted by the CLI as description text, so `task_add`/`task_modify`
  refuse `udas` outright. Ownership/assignment/evidence travel in tags +
  annotations, matching what worker agents already do.
- **Hyphenated lifecycle tags** (`ready-for-review`, `agent-created`, …).
  Underscore spellings are accepted and normalized. Tag filtering is done
  client-side after `export` because hyphenated tags mis-parse in CLI filter
  expressions (262 returned vs 44 actually tagged).
- **Lifecycle transitions require `status:pending`** (claim/start/stop/
  submit/approve/complete/release); completed tasks are immutable to these
  tools. `force:true` overrides guards when you mean it.
- **Sync failures stop, don't retry**, per agent rules.

## Develop

```sh
npm install
npm test          # 29 unit tests (node:test, no task binary needed)
npm run typecheck # tsc --noEmit against @opencode/plugin v2
```

`src/task.mjs` holds all testable logic (validation, guards, arg builders);
`src/tools.ts` defines the 22 tool descriptors (name, description, schema,
handler) exactly once; `src/index.ts` is the thin OpenCode plugin wrapper
and `src/mcp-server.ts` is the MCP server entry point (`taskwarrior-mcp`
bin) — both consume `createTools()` from `tools.ts`.

### Integration tests

`tests/integration.test.mjs` exercises the tools against a real `task`
binary and sync server. It is **not** run by `npm test` — run it explicitly:

```sh
node --test tests/integration.test.mjs
```

It uses your configured task binary (`TASK_BIN`) and profile (`TASKRC`), so
point those at a scratch/test profile first: it creates real tasks.

## Related

- [task-drain](https://github.com/ncdlabs/task-drain) -- autonomous Taskwarrior queue drain workers using OpenCode. The workers use direct `task` shell commands and do not require this plugin, but it provides the same operations as native agent tools.
