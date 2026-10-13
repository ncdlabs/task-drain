# Troubleshooting and recovery

## Start with observable state

```bash
drain help
drain logs
task --version
task sync
```

`task sync` exchanges real data. `drain status` also attempts sync and may
query GitHub. To inspect only local dashboard state, use
`DRAIN_NO_SYNC=1 drain status`; this still may query GitHub for PRs.
Match `DRAIN_AUTONOMOUS` to the worker configuration when comparing queue
counts. Logs include worker identity, selected UUID, exit code, and outcome.

## Workers exit immediately

Inspect the latest worker log. Check the selected CLI is on the scripts'
fixed PATH, jq is installed, and `TASK` resolves to an executable absolute
path. Direct worker mode refuses to start while STOP exists; `drain start`
clears it. A launch message alone does not prove successful initialization.

If direct execution through `~/bin/task-drain.sh` reports missing libraries,
use `drain` or the worker's actual path inside the clone.

## Sync fails or appears to hang

Run ordinary `task sync` with the same exported `TASKRC`. Check the server,
network, TLS, pool identity, and encryption configuration without printing
secrets. Different client IDs create different pools, not cooperating replicas.

The shell's fallback invokes sudo on any sync failure and can wait for sudo
authentication. Three retries do not bound time spent inside sync/sudo.
The plugin uses ordinary sync with no sudo fallback or retry loop. Fix
normal-user connectivity instead of interpreting sudo success as a diagnosis.
After privileged attempts, inspect ownership of the actual data directory;
HOME/TASKRC forwarding alone does not guarantee ownership remains unchanged.

After a plugin write followed by a sync error, inspect local task state
before retrying. The write may already have happened; blindly repeating
`task_add` or `task_auto` can create duplicates.

## A task is not picked up, or an unexpected task is picked up

Export that UUID and inspect status, `start`, tags, dependency state, and
project. Compare with the exact filters in [operating modes](operating-modes.md).
A future scheduled date is not the same as waiting state. Autonomous mode
requires `auto` but ignores `noauto`. Review/approval and plugin `claimed`
tags are not worker exclusions. Project filtering and repo mapping use
different matching rules: map subprojects explicitly.

For a task to remain outside both shell modes, add `noauto`, remove `auto`,
and sync. This does not cancel already-running work and does not constrain
plugin `task_auto`.

## Many tasks fail with the same agent error

Stop the supervisor and workers; inspect logs before requeueing. An unavailable
model, invalid flag, missing authentication, or denied permission can fail
every task. `DRAIN_MODEL` and `DRAIN_SKIP_PERMISSIONS` affect OpenCode only;
`OPENCODE_RUN_FLAGS` is not an environment override. Check your installed
harness help and configuration, then retry one reviewed task with one worker.
`drain unfail` changes a filtered set immediately and does not sync itself.

## Timeout or stale-claim surprises

Only `gtimeout` enables `TASK_TIMEOUT_SEC`. Check `command -v gtimeout` in the
scripts' PATH; ordinary Linux `timeout` is not detected. Stale reclamation
uses task active age, even when the agent is still running. Keep the stale
threshold longer than the intended execution window and inspect live processes
before manually releasing a claim. Reclamation requires another worker loop;
it is not a timer service that runs while all workers are stopped.

## Stopping does not seem to stop everything

`drain stop` is graceful and returns early if no workers are found. Stop the
supervisor explicitly with `drain autoscale-stop`. `drain kill` sends TERM;
it does not wait for descendants or guarantee remote claim publication.
Inspect remaining agent processes and task state. Coordinate other hosts
before releasing shared claims. `drain resume` clears stop files but starts
nothing; `drain autoscale` does not clear them automatically.

## Dashboard or PR list is incomplete

Watch syncs only its first frame; restart it to refresh remote state. History
is retained only to the worker-configured limit and can race during concurrent
pruning. PR discovery uses authenticated `gh`, GitHub origins, directory-valued
`.git`, and `Task <uuid>` body matching. It skips linked worktrees and Gitea;
query failures may look like an empty list. Verify important PRs directly.

For an incident report, include the relevant version/commit, command, selected
mode, sanitized log excerpt, and UUID. Exclude encryption secrets, tokens,
webhook URLs, and unnecessary task/repository content.
