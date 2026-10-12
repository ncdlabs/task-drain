# Uninstall

Worker files and Taskwarrior data are separate, but the installer may place
**sync-server data inside `~/.task-drain/`**. Do not recursively remove that
directory until you have decided whether to retain the server and backed it up.

## 1. Stop local execution

```bash
drain autoscale-stop
drain stop
```

Wait for active work to finish. Use `drain kill` if immediate TERM is needed;
claim cleanup is best-effort, not guaranteed. Inspect `drain status` and agent
processes before continuing. These commands do not stop remote workers.

If a claim remains after its worker has stopped, inspect the specific task,
then release only that UUID:

```bash
task '<uuid>' export
task '<uuid>' modify -drain-claimed
task '<uuid>' stop
task sync
```

Do not bulk-release `drain-claimed` tasks while other hosts may still own them.

## 2. Preserve data before deleting anything

Back up Taskwarrior configuration, its configured data directory, and the
pool encryption secret. Preserve `repos.conf`, logs, and history if needed.
If the installer created a sync server, identify its actual runtime and
mount with `docker inspect taskchampion` (substitute nerdctl or Podman).

To remove that server, sync participating replicas while it is still running,
stop the container, and back up the mounted server data before removing it:

```bash
docker stop taskchampion
# Back up the inspected data mount to a separate location now.
docker rm taskchampion
```

If keeping the server, keep its data directory and container. Removing the
server will make clients using its URL unable to sync until reconfigured.
A stopped database backup plus retained client replicas provides recovery
options; do not assume an unverified copy is sufficient.

## 3. Remove client integration and scripts

Remove the OpenCode v2 `plugins` entry or the MCP server entry from the
configured client, then reload it. For Claude Code, the registered server
can be removed with `claude mcp remove taskwarrior`. For Cursor and Codex,
remove the `taskwarrior` server from their MCP configuration.

Remove installed script links (adjust the prefix if necessary):

```bash
rm "$HOME/bin/drain" "$HOME/bin/task-drain.sh"
```

If you installed only `drain` manually, remove only that link. Restore any
installer `.bak` files deliberately after checking their contents.

## 4. Remove worker state

Delete logs, history, STOP files, `autoscale.pid`, and `repos.conf` only after
local workers have exited and required backups are complete. If retaining
the sync server, keep `~/.task-drain/taskchampion-data` intact.

Only when **all** contents are backed up or intentionally disposable:

```bash
rm -rf "$HOME/.task-drain"
```

This deletes any local sync-server data under that directory too.

## 5. Optional task-tag cleanup

Inspect exported tasks and remove `drain-failed` or `drain-claimed` by full
UUID only where appropriate, then sync. These tags are harmless to retain.
`noauto` and `auto` may still be useful for future worker runs.

Taskwarrior, jq, coreutils, Node.js, agent CLIs, the source clone, and Taskwarrior
profiles remain installed. Keep pool identity and encryption settings if the
pool remains in use. Reinstalling requires rebuilding the plugin, restoring
mappings, and verifying sync and agent access before starting workers.
