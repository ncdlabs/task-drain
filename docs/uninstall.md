# Uninstall

Removal is the reverse of installation, in this order. Nothing here touches
your Taskwarrior tasks — they live in Taskwarrior, not in task-drain.

## 1. Stop everything

```bash
drain autoscale-stop   # stop the supervisor (workers keep running)
drain kill             # TERM all workers mid-task; claims released to pending
```

Prefer `drain stop` (graceful — workers finish their current task) if nothing
is on fire. Verify nothing is left:

```bash
drain status           # should show "none running"
```

If a worker was killed hard (`kill -9`) and its claim survived, release it
by hand:

```bash
task +drain-claimed +ACTIVE export | jq -r '.[].uuid' | while read -r u; do
  task "$u" modify -drain-claimed
  task "$u" stop
done
task sync
```

## 2. Remove the scripts

```bash
rm ~/bin/task-drain.sh ~/bin/drain
```

If you installed with `PREFIX=/usr/local` (or another prefix), remove them
from `$PREFIX/bin` instead. If the installer backed up pre-existing files
(`drain.bak`), restore or delete those as you prefer.

## 3. Remove worker state

```bash
rm -rf ~/.task-drain
```

This deletes the kill-switch files, the autoscaler PID file,
`repos.conf`, `history.log`, and all worker logs. Your `repos.conf`
mappings are worth copying elsewhere first if you plan to reinstall.

## 4. Remove the plugin (if installed)

- **OpenCode plugin** — remove the `<path>/plugin` entry from the
  `plugins` array in your `opencode.json(c)` and reload.
- **Claude Code** — `claude mcp remove taskwarrior`
- **Cursor** — delete the `taskwarrior` entry from `~/.cursor/mcp.json`
- **Codex** — delete the `[mcp_servers.taskwarrior]` section from
  `~/.codex/config.toml`

## 5. Remove the local sync server (if install.sh created one)

```bash
docker stop taskchampion && docker rm taskchampion
# (use nerdctl/podman instead of docker if that's what you run)
```

Its data lived under `~/.task-drain/taskchampion-data`, already removed in
step 3. **Do not do this if the sync server holds the only copy of your
tasks** — make sure every replica has synced (`task sync` on each machine)
before removing server data.

## 6. Optional: clean drain tags from tasks

`drain-failed` and `drain-claimed` are ordinary Taskwarrior tags. They are
harmless if left in place, but to remove them entirely:

```bash
task +drain-failed modify -drain-failed
task +drain-claimed modify -drain-claimed
task sync
```

`noauto` tags are yours — keep them if you still want those tasks excluded
from any future worker runs.

## What stays behind

- **Your tasks, projects, tags, and annotations** — Taskwarrior data is
  never deleted by uninstalling task-drain.
- **Taskwarrior, jq, coreutils, your agent CLI, Node.js** — dependencies
  installed by `install.sh` or by hand are left alone; remove them with
  your package manager if you want them gone.
- **The sync server configuration** in your `taskrc`
  (`sync.server.url`, `sync.server.client_id`) — still valid for plain
  `task` use.

## Reinstalling later

Re-clone, re-run `./install.sh` (idempotent), recreate
`~/.task-drain/repos.conf` from your backup, and `drain start` again.
