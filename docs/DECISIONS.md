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

## 2026-10-24 — Final review: worker registry pruning, cross-host claim analysis

**Context.** Independent re-review of `8390832` plus controlled production
validation. The registry `~/.task-drain/workers/<pid>` (written once at
worker startup, removed on EXIT trap) was never pruned: a worker killed with
KILL leaves a stale entry, and a later PID reuse matching the recorded
project filter miscounts scale-up/scale-down. The cross-host claim window
was demonstrated empirically: two `claim_task` runs against replicas that
had not yet synced each other's claim both succeeded (both would launch
agents), because Taskwarrior/TaskChampion offer no compare-and-swap —
`modify`/`annotate`/`start`/`sync` is a non-atomic sequence and
last-writer-wins on convergence.

**Decision.** Prune dead-PID registry entries inside `scoped_worker_pids`
(remove the entry file only, only when `kill -0` fails, never signaling
anyone). Same-host double execution stays prevented by the per-task
`locks/<uuid>` mutex (verified in code and covered by the existing
exactly-one-acquires test). Cross-host gets no code change: without a
server-side atomic primitive any client-side check is still racy, so the
fix is a deployment constraint — autonomous execution on at most one host —
plus a fail-closed rule (sync failure aborts the claim; `start` failure
aborts the claim) and an operator rule (never `force:true`-claim
`drain-claimed` tasks while workers run). Task-lock (`locks/<uuid>`)
staleness after KILL remains operator-recovered (`rm` the entry); only the
registry is auto-pruned.

**Alternatives considered.**
- Client-side post-claim re-verification (re-export, check our annotation
  is last) — rejected: still racy under the same sync latency, adds
  complexity without atomicity.
- Redis/Postgres/Kubernetes coordination — rejected per scope: unneeded for
  the documented single-host deployment model; recorded as the prerequisite
  if multi-host autonomy is ever required.

## 2026-10-25 — Reliability hardening: stale-lock recovery, bounded sync, claim protection, reaping, host guard

**Context.** Follow-up hardening pass over the remaining operational gaps
left by the two prior audits. A worker terminated with SIGKILL left
`locks/<uuid>` behind (PID-only, no ownership proof), requiring manual `rm`
before the task could run again. Every `task sync` was unbounded: a hung
sync blocked the worker/supervisor forever and SIGTERM deferred until the
sync or `sleep` finished. Plugin `claim`/`start` with `force:true` could
silently take over an active `drain-claimed` task. The supervisor spawned
workers with `&` and never waited on them, so each exited worker lingered
as a zombie and inflated counts until the supervisor itself exited. No
in-app guard existed against accidentally starting a second autonomous
deployment on another host sharing the same TaskChampion pool.

**Decision.**
- *Stale locks:* lock dirs now carry verifiable owner identity (`pid`,
  `host`, `worker`, `created`, `proc_start` = owner process start time).
  `acquire_lock_with_recovery` reclaims and retries once when the holder is
  provably abandoned (dead PID, or same-host PID reuse proven by
  process-start mismatch); `reclaim_abandoned_locks` sweeps stale dirs at
  worker startup and each loop iteration. Live, young (within
  `DRAIN_LOCK_GRACE_SEC`, default 10s), partially written, cross-host, and
  legacy-live locks are kept (fail closed). Legacy pid-only locks are
  reclaimed only when their PID is dead. Reaping removes directories only,
  never signals anyone.
- *Sync:* each attempt is capped by `DRAIN_SYNC_TIMEOUT_SEC` (default 30s,
  min 5s; `timeout(1)` when available, background-watchdog emulation
  otherwise), retried at most `DRAIN_SYNC_RETRIES` times (default 3) with
  exponential backoff from `DRAIN_SYNC_RETRY_DELAY` (floor 1s), and all
  waits (sync `wait`, retry sleeps) are SIGTERM-interruptible — the
  in-flight sync child is tracked in `SYNC_PID` and killed by the signal
  trap. Failures are logged as temporary (network/server, retryable) vs
  permanent (auth/config, needs operator action); required sync failures
  abort the operation and a task is never executed when its claim cannot be
  published.
- *Claim protection:* plugin `claimGuard`/`startGuard` reject `force:true`
  takeover of `drain-claimed` tasks. An explicit `overrideDrainClaim:true`
  plus a non-empty `overrideReason` is required, and the override is
  recorded as a `[actor] drain-override:` annotation. Shell eligibility
  already excludes plugin-`claimed` tasks, so the shell side needed no
  protocol change.
- *Reaping:* the supervisor tracks the workers it spawns and reaps exited
  ones every iteration (and at shutdown); reaping only `wait`s on
  supervisor-spawned PIDs and never signals anyone.
- *Host guard:* optional fail-closed single-host enforcement via
  `worker.primary_host` / `DRAIN_PRIMARY_HOST`: `drain start`,
  `drain autoscale`, workers, and the supervisor refuse on other hosts
  unless `DRAIN_ALLOW_OTHER_HOST=1` is set explicitly (logged). Unset means
  no enforcement — the documented single-host constraint still applies.

**Alternatives considered.**
- Age-only lock deletion — rejected: long-running tasks legitimately hold
  locks for hours; only provable abandonment authorizes reclamation.
- Permanent-failure fast path with no retries — rejected: preserves the
  existing 3-attempt semantics; permanence is a log classification, and all
  paths still fail closed.
- Blocking all plugin writes to `drain-claimed` tasks even with override —
  rejected: would break deliberate administrative recovery; the explicit
  auditable override is the middle ground.
- Daemonizing workers under a process supervisor for reaping — rejected:
  overkill; explicit `wait`-based reaping is the minimal correction.

**Remaining limitations (not fixed here).** Cross-host duplicate execution
is still possible when two hosts run autonomously (no atomic CAS in
TaskChampion; the host guard only stops *accidental* deployment, not a
deliberate override on two machines). Claim annotations carry PIDs without
start-time identity, so stale-claim release still trusts `kill -0` plus age
and can release a task whose PID was reused cross-invocation on the same
host. Plugin actors are unauthenticated labels; the override annotation is
auditable but not unforgeable. See architecture.md.
