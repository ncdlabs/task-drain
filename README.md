# task-drain

Autonomous Taskwarrior queue drain workers using OpenCode.

## Scripts

- `task-drain.sh` -- the worker loop: syncs Taskwarrior, claims the highest-urgency eligible task, runs `opencode run` non-interactively, verifies, repeats until the queue is empty.
- `drain` -- CLI wrapper: `status`, `start [N]`, `stop`, `kill`, `logs`, `docs`.

## Usage

```bash
bash ~/bin/drain start 2        # start 2 workers
bash ~/bin/drain status         # check workers and queue
bash ~/bin/drain stop           # graceful stop
```

## Tags

- `noauto` -- opt out of worker pickup
- `drain-failed` -- worker attempted but couldn't complete; needs human review
- `drain-claimed` -- in-flight by a worker (auto-released after 4h if stale)

Kill switch: `~/.task-drain/STOP`

## Related

- [opencode-tasks](https://github.com/ncdlabs/opencode-tasks) -- OpenCode plugin exposing Taskwarrior lifecycle tools as native agent tools. Optional companion; the drain workers use direct `task` shell commands and don't require it.
