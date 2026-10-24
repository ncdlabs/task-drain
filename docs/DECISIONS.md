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
does. The implemented autonomous filter requires `auto` and still excludes
`noauto` (code-as-is); whether autonomous *should* ignore `noauto` is an
open owner decision. An already-running supervisor is not reconfigured by that command.
These are descriptions of the current implementation, not new design decisions.

Use `drain autoscale-stop` and deliberate worker stop/restart controls when
updating installed code. The broad historical `pkill` example can match
other worker invocations; inspect local processes before using it.

## 2026-10-13 — Plugin completion requires +approved; doc-review verification pass

`completeGuard` requires `+approved`; `+ready-for-review` no longer suffices.
`force:true` bypasses the approval check but requires a `note`. This
describes the implemented policy, not a human-approval authentication
mechanism: actor labels remain caller-provided annotations.

The 2026-10-12 documentation review findings were verified against the
current source. Eight findings were documentation lag behind already-landed
code (merge verification, stop/autoscaler ordering, completion exit-code
conjunction, reclaim liveness check, worker claim/review exclusions,
setup overwrite/symlink handling) and were corrected in place. The
`noauto`-in-autonomous question is recorded as pending owner policy, not
decided here.

## 2026-10-24 — Supervisor single-instance guard and PID-identity checks

**Context.** Regression testing launched several real autoscalers that
survived as PPID-1 orphans with no pidfile registration, while `drain status`
reported zero workers (supervisors are tracked separately and were never
counted). SIGTERM did not stop them within seconds, and the old
check-then-launch (`[ -f pidfile ] && kill -0 $(cat pidfile)`) had a
check-and-launch race, trusted PIDs without command-line verification, and
removed the pidfile unconditionally on stop.

**Decision.** Guard `drain autoscale` / `autoscale-stop` / `status` with
`lib/supervisor.sh`: liveness is PID plus `task-drain.sh … autoscale`
command-line identity; concurrent launches serialize through a transient
`autoscale.starting` mkdir mutex; stale registrations (dead PID, garbage,
or PID reuse) never block startup and never authorize a kill; the
supervisor's poll sleep is interruptible so TERM exits promptly; pidfile
removal happens only under the launch mutex while it still names the exiting
process. `drain status` warns about unregistered (orphan) supervisors and no
longer aborts its queue section when the task query fails.

**Alternatives considered.**
- `flock`-based locking — rejected: not installed by default on macOS and
  a new dependency for a shell project; `mkdir` atomicity is sufficient for
  the millisecond check-and-launch window.
- A per-project supervisor registry — rejected: changes the existing
  one-supervisor-per-host behavior and CLI contract; the guard preserves it.
- Claiming the supervisor lock also fixes cross-host double-claim — rejected
  as a claim: host-local state cannot coordinate machines sharing the
  TaskChampion pool. Documented as a remaining risk instead.

**Follow-up.** Each host still runs at most one supervisor; operators must
coordinate across hosts. Test fixtures use isolated HOME plus stub scripts
named `task-drain.sh`, never real workers or the production queue.
