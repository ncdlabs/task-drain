# Operating modes

The plugin and shell workers share Taskwarrior data but have independent
execution and ownership protocols. See [architecture](architecture.md).

## Mode 1: task layer only (no workers)

Install the [plugin or MCP server](installation.md#plugin-install-task-layer-only)
to expose 22 Taskwarrior tools to an agent client. The plugin does not launch
coding agents or a background queue consumer. The client decides when to
call tools; an autonomous client can still use them without human interaction.

The intended workflow is sync → claim → start → work → submit for review →
approve → complete. Actual guards are narrower: starting does not require
ownership, and completing accepts `ready-for-review` without approval.
Read [the tool reference](plugin-tools.md) before treating this as an approval gate.

`drain status`, `drain history`, and `drain projects` provide dashboards
without starting agents. `status` can synchronize data and query GitHub;
these are not strictly local, read-only operations.

## Mode 2: autonomous workers

Workers select tasks, claim them, invoke an agent, and inspect task completion
status. The prompt asks the agent to test work and open PRs; the shell does
not verify those artifacts. See [execution boundaries](architecture.md).

| Mode | Normal queue filter |
|---|---|
| Default | `+PENDING -ACTIVE -WAITING -BLOCKED -noauto -drain-failed` |
| Autonomous | `+PENDING -ACTIVE -WAITING -BLOCKED +auto -drain-failed` |

Autonomous mode does **not** exclude `noauto`. To withhold a task from both
modes, remove `auto` and add `noauto`. A future `scheduled` date alone is not
an exclusion in these filters; use Taskwarrior waiting state to defer pickup.
Project filters use Taskwarrior `project:` matching, including its subproject
semantics; repository mapping still matches the task's exact project string.

For a bounded first run, configure the repository mapping and agent, tag one
reviewed task `auto`, and run:

```bash
DRAIN_AUTONOMOUS=1 drain status myproject
DRAIN_AUTONOMOUS=1 drain start 1 myproject
```

This starts one worker without the autoscaler. `drain start --autonomous`
also launches a supervisor, potentially growing beyond the initial worker
count. An existing supervisor keeps its previous configuration.

## Operational controls

- `drain stop` requests graceful completion of current tasks; `drain kill`
  sends TERM and stops the local supervisor. Cleanup is best-effort. If no
  workers exist, `drain stop` returns without setting STOP or stopping a
  supervisor; use `drain autoscale-stop` explicitly.
- `drain-failed` parks incomplete attempts. `--failed` snapshots retries per
  worker; it is not a global one-retry guarantee. Prefer one worker for retries.
- `DRAIN_SKIP_PERMISSIONS=1` appends a bypass flag to OpenCode only. Claude
  and Codex retain their configured permissions. Harness behavior can include
  denying an action or failing a run, not necessarily waiting for a prompt.
- Stale claim release is based on age and runs only when workers loop. It
  does not establish that the previous worker died.
- Workers share mapped working directories. Multiple workers in one checkout
  can conflict even when they select different tasks.

Use the plugin when an agent client should manage task lifecycle explicitly.
Use workers for well-specified tasks with suitable repository isolation and
an understood permission configuration. See [troubleshooting](troubleshooting.md)
for recovery and [uninstall](uninstall.md) for preserving server data.
