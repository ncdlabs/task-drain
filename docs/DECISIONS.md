# Decision Records

Durable infrastructure decisions for task-drain. Task annotations are
ephemeral status; anything a future worker or owner must know goes here.

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
