# Configuration (canonical reference)

`~/.task-drain/config.yaml` (override with `DRAIN_CONFIG=/path/to.yaml`) is the
human-readable source of host-specific application configuration. All
operational settings have exactly one authoritative definition in
`lib/config-schema.json`, resolved by `lib/drain-config.py` (shell) and
`plugin/src/drain-config.mjs` (TypeScript plugin) with identical semantics.

Other documents link here rather than duplicating values. When in doubt,
`drain config show` and `drain config validate` describe the running system.

## Schema

Every key below is `section.name`. Unknown keys are rejected. A missing file
is supported (all defaults). An existing but invalid file fails closed:
workers, supervisors, claims, and mutations refuse to start (exit 2).

| Setting | Type | Default | Range / values |
|---|---|---|---|
| `worker.primary_host` | hostname or null | null (unset) | `[a-z0-9.-]`, short or FQDN |
| `worker.agent` | enum | `opencode` | `opencode` \| `claude` \| `codex` |
| `worker.model` | string | `opencode-go/longcat-2.5-preview-free` | 1–200 chars |
| `worker.owner` | string | `the project owner` | 1–200 chars |
| `worker.skip_permissions` | bool | `false` | `0/1`, `true/false`, `yes/no`, `on/off` (case-insensitive) |
| `worker.autonomous` | bool | `false` | as above; CLI `--autonomous` |
| `worker.retry_failed` | bool | `false` | as above; CLI `--failed` |
| `worker.persist` | bool | `false` | as above; CLI `--persist` |
| `worker.persist_poll_seconds` | int | `10` | 1–3600 |
| `worker.allow_home` | bool | `false` | as above |
| `worker.allow_sudo` | bool | `false` | as above |
| `worker.task_timeout_seconds` | int | `14400` | 1–604800 |
| `worker.stale_after_seconds` | int | `14400` | 60–604800 |
| `supervisor.min_workers` | int | `1` | 0–32; CLI `--min`; `min <= max` enforced |
| `supervisor.max_workers` | int | `8` | 1–32; CLI `--max` |
| `supervisor.interval_seconds` | int | `30` | 1–3600 |
| `supervisor.tasks_per_worker` | int | `2` | 1–100 |
| `supervisor.startup_lock_max_age_seconds` | int | `120` | 1–3600 |
| `sync.timeout_seconds` | int | `30` | 5–300 |
| `sync.retries` | int | `3` | 1–10 |
| `sync.retry_delay_seconds` | int | `3` | 1–300 |
| `locks.grace_seconds` | int | `10` | 0–300 |
| `history.limit` | int | `20` | 1–1000; CLI `--limit` |
| `display.watch_interval_seconds` | int | `5` | 2–3600 |
| `display.verbose` | bool | `false` | as above; CLI `--verbose`/`-v` |
| `logging.level` | enum | `info` | `debug` \| `info` \| `warn` \| `error`; YAML-only (`DRAIN_DEBUG=1` is a legacy alias for `debug`) |
| `paths.git_root` | path | `$HOME/git` | leading `~`/`$HOME` expanded |
| `paths.task_bin` | path | `task` | dynamic fallback to `/opt/homebrew/bin/task` when present |
| `paths.opencode_bin` | string | `opencode` | 1–500 chars |
| `paths.claude_bin` | string | `claude` | 1–500 chars |
| `paths.codex_bin` | string | `codex` | 1–500 chars |
| `task.taskrc` | path or null | null | profile path |
| `task.auto_sync` | bool | `true` | plugin only; `TASK_AUTO_SYNC=0` disables |

Free-form maps (validated structurally, not enumerated):

```yaml
repos:
  myproject:
    path: ~/custom/path   # local checkout
    url: https://example.com/myproject.git  # auto-clone source
remotes:
  llama:
    ssh: /home/hatch/bin/llama-ssh
    git_root: /Users/lou/git
default_remote: ""        # empty = local
```

`repos.conf` (`~/.task-drain/repos.conf`, `project=path` plus
`project.url=url`) remains supported as a legacy layer beneath YAML
(`repos.<project>.path/url` wins). New installs should use YAML.

## Precedence

High to low: explicit CLI arguments > environment variables > YAML >
schema defaults.

- CLI parser defaults never override YAML: unset flags fall through to the
  resolver instead of injecting `1`/`8`/etc.
- Unset environment variables never override anything.
- Empty environment values are treated as unset (documented behavior).
- `drain config show` prints the winning source per key
  (`default` \| `yaml` \| `environment` \| `cli`).

## Environment variable mapping

Each canonical key has one primary `DRAIN_*` (or legacy) variable.
`paths.task_bin` accepts `TASK` (primary) and `TASK_BIN` (plugin alias);
setting both to different values is an error.

| YAML key | Env var |
|---|---|
| `worker.primary_host` | `DRAIN_PRIMARY_HOST` |
| `worker.agent` | `DRAIN_AGENT` |
| `worker.model` | `DRAIN_MODEL` |
| `worker.owner` | `DRAIN_OWNER` |
| `worker.skip_permissions` | `DRAIN_SKIP_PERMISSIONS` |
| `worker.autonomous` | `DRAIN_AUTONOMOUS` (+ CLI `--autonomous`) |
| `worker.retry_failed` | `DRAIN_RETRY_FAILED` (+ CLI `--failed`) |
| `worker.persist` | `DRAIN_PERSIST` (+ CLI `--persist`) |
| `worker.persist_poll_seconds` | `DRAIN_PERSIST_POLL_SEC` |
| `worker.allow_home` | `DRAIN_ALLOW_HOME` |
| `worker.allow_sudo` | `DRAIN_ALLOW_SUDO` |
| `worker.task_timeout_seconds` | `TASK_TIMEOUT_SEC` |
| `worker.stale_after_seconds` | `STALE_AFTER_SEC` |
| `supervisor.min_workers` | `DRAIN_MIN_WORKERS` (+ CLI `--min`) |
| `supervisor.max_workers` | `DRAIN_MAX_WORKERS` (+ CLI `--max`) |
| `supervisor.interval_seconds` | `DRAIN_AUTOSCALE_INTERVAL` |
| `supervisor.tasks_per_worker` | `DRAIN_TASKS_PER_WORKER` |
| `supervisor.startup_lock_max_age_seconds` | `DRAIN_STARTUP_LOCK_MAX_AGE_SEC` |
| `sync.timeout_seconds` | `DRAIN_SYNC_TIMEOUT_SEC` |
| `sync.retries` | `DRAIN_SYNC_RETRIES` |
| `sync.retry_delay_seconds` | `DRAIN_SYNC_RETRY_DELAY` |
| `locks.grace_seconds` | `DRAIN_LOCK_GRACE_SEC` |
| `history.limit` | `DRAIN_HISTORY_LIMIT` (+ CLI `--limit`) |
| `display.watch_interval_seconds` | `DRAIN_WATCH_INTERVAL` |
| `display.verbose` | `DRAIN_VERBOSE` (+ CLI `--verbose`) |
| `logging.level` | YAML-only (+ legacy `DRAIN_DEBUG=1` ⇒ `debug`) |
| `paths.git_root` | `GIT_ROOT` |
| `paths.task_bin` | `TASK` (also `TASK_BIN` for the plugin) |
| `paths.opencode_bin` | `OPENCODE_BIN` |
| `paths.claude_bin` | `CLAUDE_BIN` |
| `paths.codex_bin` | `CODEX_BIN` |
| `task.taskrc` | `TASKRC` |
| `task.auto_sync` | `TASK_AUTO_SYNC` (`0` disables) |

Deprecated generic overrides `DRAIN_CONFIG_<UPPER_DOTS_TO_UNDERSCORES>`
(e.g. `DRAIN_CONFIG_WORKER_ALLOW_SUDO`) still map through the same
validation but are deprecated in favor of the table above.

Environment-only (never in YAML by design):

| Env | Purpose |
|---|---|
| `DRAIN_ALLOW_OTHER_HOST=1` | Explicit auditable override for the primary-host guard |
| `DRAIN_ERROR_WEBHOOK` | Webhook URL for critical failures (secret — never logged) |
| `DRAIN_WEBHOOK_FORMAT` | `slack` (default) \| `discord` |
| `DRAIN_CONFIG` | Override config file path (bootstrap) |
| `DRAIN_HOME` | Override state dir (bootstrap) |
| `PROJECT_FILTER` | Runtime project scope (CLI sets this) |
| `FORGE_TOKEN` | Forge API token for PR creation (secret) |
| `DRAIN_FORCE_COLOR`, `NO_COLOR`, `COLUMNS` | Display only |
| Installer-only: `PREFIX`, `SKIP_DEPS`, `SKIP_PLUGIN`, `TASKCHAMPION_URL`, `TASKCHAMPION_LOCAL`, `CONTAINER_RUNTIME`, `PLUGIN_DIR` | See [installation](installation.md) |

Boolean parsing is strict and identical in shell and TypeScript:
`1/true/yes/on` ⇒ true, `0/false/no/off` ⇒ false (case-insensitive).
Anything else fails validation with the expected set.

## CLI

```bash
drain [--config PATH] config show [--json]  # effective config + provenance; secrets never shown
drain [--config PATH] config validate       # nonzero exit + actionable errors on failure
drain [--config PATH] config path            # active file path
drain [--config PATH] config defaults        # commented template to stdout; modifies nothing
drain [--config PATH] config init            # create template (mode 600) only when absent; never overwrites
```

`--config` / `DRAIN_CONFIG` works consistently across all subcommands.
Inspection commands are side-effect-free except the explicit `init` write.

## Provenance

`drain config show` prints `key  value  source`. `--json` emits
`{values, sources, config_path, config_present}` for tooling. Secret values
are never displayed (env-only secrets are never read from YAML).

## Error handling

- Missing file ⇒ defaults (supported).
- Existing invalid file ⇒ error before any side effect (exit 2):
  `drain start` / `drain autoscale` / workers / supervisors refuse to run.
- Errors name the invalid key, the offending value's source, and the
  expected type/range. Secret values are redacted.
- No silent fallback, no partial application, no automatic overwrites.

## File permissions

`drain config init` and `install.sh` create `config.yaml` with mode `600`.
The file holds no secrets by design (`DRAIN_ERROR_WEBHOOK`, `FORGE_TOKEN`
stay in the environment). `600` is defense-in-depth for host identity and
repo paths.

## Secret management

Secrets are environment-only. YAML validation rejects sensitive keys if they
ever appear in YAML. Error messages and `config show` never echo secret
values. Do not commit tokens or webhook URLs to the config file.

## Restart requirements

Configuration is a startup snapshot, loaded once per process. Changing YAML
or environment does not reconfigure running workers or the supervisor.
Restart them explicitly (`drain stop` / `drain autoscale-stop`, then `start` /
`autoscale`). There is no hot-reload.

## Primary-host restrictions

Autonomous execution is single-host (TaskChampion sync has no atomic claim;
see [architecture](architecture.md)). The designated executor is configured
 once:

```yaml
worker:
  primary_host: llama
```

- Hosts compare short names and FQDNs with dot-boundary matching only:
  `llama` ≡ `llama.example.com`, but `llama` ≢ `llama2`.
- Non-primary hosts refuse `drain start`, `drain autoscale`, workers, and
  supervisors unless `DRAIN_ALLOW_OTHER_HOST=1` (auditable override, logged).
- Unset `worker.primary_host` preserves legacy behavior (no enforcement).
- Invalid host config fails closed.
- Enforcement is an accident guard, not distributed coordination.

## Backward compatibility and migration

- All `DRAIN_*` variables in the table above keep working; env beats YAML,
  CLI beats env.
- `repos.conf`, `DRAIN_AUTONOMOUS=1` without `--autonomous`, and
  config-less installs behave as before.
- New installs get a `600` template with no autonomy and no invented
  primary host. Existing installs are never overwritten (`drain config init`
  refuses when the file exists; `install.sh` validates but leaves invalid
  files untouched for the operator).
- `DRAIN_CONFIG_WORKER_*` generic overrides still validate but are deprecated.

## Verified examples

MacBook-Air-3008 (non-executor) — current production file, valid as-is:

```yaml
# task-drain local configuration — MacBook-Air-3008 (non-executor)
worker:
  primary_host: llama
```

`drain config validate` passes; `drain start` / `drain autoscale` refuse
without `DRAIN_ALLOW_OTHER_HOST=1`. No workers run here.

`llama` (designated executor) — minimal production example:

```yaml
worker:
  primary_host: llama
  agent: opencode
  model: opencode-go/longcat-2.5-preview-free

supervisor:
  min_workers: 1
  max_workers: 8
  interval_seconds: 30

sync:
  timeout_seconds: 30
  retries: 3
  retry_delay_seconds: 1
```

Only settings from the schema above are supported. Tune `supervisor.*`
and `sync.*` per host; keep `worker.primary_host: llama` identical on all
hosts so non-executors refuse automatically.
