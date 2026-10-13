# Decision Records

Historical infrastructure decisions for task-drain. Taskwarrior holds work
status; stable rationale belongs here. Incident observations below are not
universal platform guarantees. Current behavior is documented in
[architecture](architecture.md) and [installation](installation.md).

## 2026-10-09 — Drain sync: sudo fallback for macOS Local Network Privacy

**Context.** macOS 26 (26.5.1) Local Network Privacy blocks third-party
(Homebrew, unsigned) binaries from reaching the LAN taskserver
(192.168.1.109:443): `/opt/homebrew/bin/task sync` fails with EHOSTUNREACH
(errno 65, "No route to host") for the whole drain process chain
(launchd → bash drain → gtimeout → opencode), because the opencode binary
has no Local Network permission. Apple binaries (`/usr/bin/curl`,
`/usr/bin/openssl`, `/usr/bin/nc`) and root processes are unaffected, and
the taskserver itself is healthy (TaskChampion sync server v0.7.1).

**Decision.** `task-drain.sh` syncs through a `task_sync()` wrapper: try
the direct sync; if it fails, retry under `sudo` (root bypasses LNP). sudo
runs with the user's `HOME`/`TASKRC`, so the task DB stays user-owned —
verified: no root-owned files in `~/.config/task-llama/` after sudo syncs.
Requires NOPASSWD for the task binary in sudoers. All critical sync paths
(claim, release, completion, worker start) go through
`sync_with_retry` → `task_sync`, which also absorbs the intermittent
taskserver flakiness (3 attempts, exponential backoff).

**Alternatives considered.**
- Grant opencode Local Network permission in System Settings > Privacy &
  Security > Local Network — user-side GUI fix; still recommended as the
  long-term answer, because LNP may also affect other network access the
  drain/opencode chain needs.
- Approve the one-time LNP prompt interactively — same; user-side.
- Apple-signed helper or tunnel to the taskserver — more moving parts;
  rejected for now.

**Follow-up.** Drain workers running old code must be restarted once to
pick up the sudo fallback (`pkill -f task-drain.sh`, then
`drain autoscale` or start workers as usual).

## 2026-10-12 — Opt-in autonomous mode

**Context.** Pickup was opt-out: any pending task was eligible unless tagged
`noauto`. This meant a freshly added task could be grabbed by a worker before
the owner had a chance to review it. The owner asked for autonomous
processing to be opt-in instead.

**Decision.** Added `DRAIN_AUTONOMOUS` env var and `--autonomous` flag on
`drain start`. When enabled, pickup requires `+auto` tag on each task —
nothing is picked up unless explicitly tagged. The autoscaler is launched
automatically to pick up new tickets as they are tagged. Default behavior
(opt-out via `noauto`) is unchanged for existing users.

**Alternatives considered.**
- Flip the default to opt-in — rejected: breaking change for existing users;
  the flag gives them the opt-in behavior without disrupting current setups.
- Separate `drain autoscale --autonomous` flag — rejected: one flag on
  `drain start` is simpler and keeps the autoscaler launch in one place.

**Follow-up.** Existing users who want opt-in pickup should run
`drain start --autonomous` and tag tasks with `+auto`.

## 2026-10-12 — Documentation review qualifications

The earlier macOS entry records a local incident, not a general assertion
that Apple binaries or root always bypass network privacy. The implemented
fallback is `sudo env HOME=… TASKRC=… <task> sync` after any sync failure.
It does not preserve effective user identity, verify file ownership, or
validate sudo policy. A NOPASSWD rule for the task binary alone may not match
this invocation. Prefer repairing ordinary-user access.

The autonomous-mode decision applies to worker selection. Setting the env
variable alone does not launch the supervisor; `drain start --autonomous`
does. The actual autonomous filter requires `auto` and does not exclude
`noauto`. An already-running supervisor is not reconfigured by that command.
These are descriptions of the current implementation, not new design decisions.

Use `drain autoscale-stop` and deliberate worker stop/restart controls when
updating installed code. The broad historical `pkill` example can match
other worker invocations; inspect local processes before using it.
