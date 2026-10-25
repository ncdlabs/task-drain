#!/usr/bin/env bash
# lib/config.sh — thin shell adapter over the authoritative resolver.
#
# Single authoritative resolver: lib/drain-config.py + lib/config-schema.json.
# This file contains NO defaults, NO type conversion, NO validation, and NO
# precedence logic. It delegates to drain-config.py once per process, caches
# the resolved JSON, and exposes read-only accessors.
#
# Backward compatibility: config_get / config_get_bool keep their signatures
# for map sections (repos.*, remotes.*, default_remote) and resolved settings.
# New code should prefer drain_config_value / drain_config_source.

_DRAIN_CONFIG_LOADED=""
_DRAIN_CONFIG_JSON=""
_DRAIN_CONFIG_ERROR=""
_DRAIN_CONFIG_PATH=""
_DRAIN_RESOLVER_DIR=""

_drain_resolver_dir() {
	local src="${BASH_SOURCE[0]}"
	while [ -L "$src" ]; do
		local target
		target=$(readlink "$src")
		case "$target" in /*) src="$target" ;; *) src="$(dirname "$src")/$target" ;; esac
	done
	(cd "$(dirname "$src")" && pwd)
}

# drain_config_load [--set key=value ...] — resolve once per process.
# Additional --set args after the first load are ignored (first wins; callers
# must pass explicit CLI overrides on first load).
drain_config_load() {
	if [ -n "$_DRAIN_CONFIG_LOADED" ]; then return 0; fi
	_DRAIN_CONFIG_LOADED=1
	_DRAIN_RESOLVER_DIR="$(_drain_resolver_dir)"
	local cfg="${DRAIN_CONFIG:-$HOME/.task-drain/config.yaml}"
	_DRAIN_CONFIG_PATH="$cfg"
	local py="$_DRAIN_RESOLVER_DIR/drain-config.py"
	local out rc
	if [ ! -f "$py" ]; then
		_DRAIN_CONFIG_ERROR="resolver not found: $py"
		return 0
	fi
	out=$(python3 "$py" resolve --config "$cfg" "$@" --format json 2>"${TMPDIR:-/tmp}/drain-config-err-$$") || rc=$?
	rc=${rc:-0}
	if [ "$rc" -ne 0 ]; then
		_DRAIN_CONFIG_ERROR=$(cat "${TMPDIR:-/tmp}/drain-config-err-$$" 2>/dev/null || echo "invalid configuration")
		rm -f "${TMPDIR:-/tmp}/drain-config-err-$$"
		_DRAIN_CONFIG_JSON=""
		return 0
	fi
	rm -f "${TMPDIR:-/tmp}/drain-config-err-$$"
	_DRAIN_CONFIG_JSON="$out"
	_DRAIN_CONFIG_ERROR=""
}

# drain_config_valid — 0 when the effective configuration is valid.
# Prints the actionable resolver error to stderr otherwise.
drain_config_valid() {
	drain_config_load "$@"
	if [ -n "$_DRAIN_CONFIG_ERROR" ]; then
		printf '%s\n' "$_DRAIN_CONFIG_ERROR" >&2
		return 2
	fi
	return 0
}

# drain_config_require_valid — fail closed before operational side effects.
drain_config_require_valid() {
	if ! drain_config_valid "$@"; then
		echo "drain: invalid configuration; refusing to proceed (see errors above; run: drain config validate)" >&2
		exit 2
	fi
}

_drain_json_get() { # $1 = python expression reading stdin JSON
	if [ -z "$_DRAIN_CONFIG_JSON" ]; then return 1; fi
	printf '%s' "$_DRAIN_CONFIG_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); v=($1); print('' if v is None else ('true' if v is True else ('false' if v is False else str(v))))" 2>/dev/null
}

# drain_config_value <dotted.key> — typed value rendered as string (bool as true/false).
drain_config_value() {
	drain_config_load
	if [ -n "$_DRAIN_CONFIG_ERROR" ]; then return 2; fi
	_drain_json_get "d.get('values',{}).get('$1','')"
}

# drain_config_source <dotted.key> — default|yaml|environment|cli
drain_config_source() {
	drain_config_load
	if [ -n "$_DRAIN_CONFIG_ERROR" ]; then return 2; fi
	_drain_json_get "d.get('sources',{}).get('$1','default')"
}

# drain_config_path — active config file path.
drain_config_path() {
	drain_config_load
	if [ -n "$_DRAIN_CONFIG_ERROR" ]; then
		printf '%s\n' "${_DRAIN_CONFIG_PATH:-$HOME/.task-drain/config.yaml}"
		return 0
	fi
	_drain_json_get "d.get('config_path','')" || printf '%s\n' "$_DRAIN_CONFIG_PATH"
}

# config_get <dotted.key> [default] — backward-compatible accessor.
# Serves resolved settings AND map sections (repos.*, remotes.*, default_remote).
config_get() {
	local key="$1" def="${2:-}"
	drain_config_load
	if [ -n "$_DRAIN_CONFIG_ERROR" ]; then
		printf '%s' "$def"
		return 0
	fi
	local v
	v=$(printf '%s' "$_DRAIN_CONFIG_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
vals=d.get('values',{})
maps=d.get('maps',{})
k=sys.argv[1]
if k in vals:
    v=vals[k]
    if v is None: print('',end='')
    elif isinstance(v,bool): print('true' if v else 'false',end='')
    else: print(str(v),end='')
elif k in maps:
    v=maps[k]
    if v is None: print('',end='')
    elif isinstance(v,bool): print('true' if v else 'false',end='')
    else: print(str(v),end='')
" "$key" 2>/dev/null) || v=""
	if [ -n "$v" ]; then
		printf '%s' "$v"
	else
		printf '%s' "$def"
	fi
}

# config_get_bool <dotted.key> [default] — normalize to 0/1 via resolver types.
config_get_bool() {
	local v
	v=$(config_get "$1" "${2:-false}")
	case "$v" in
	1 | true | True | TRUE | yes | Yes | YES | on | On | ON) echo 1 ;;
	*) echo 0 ;;
	esac
}

# drain_config_export_env — export canonical DRAIN_* effective values derived
# from the resolver (single place where env names are materialized for
# legacy consumers). Call once at worker/supervisor startup after validation.
drain_config_export_env() {
	drain_config_load "$@"
	if [ -n "$_DRAIN_CONFIG_ERROR" ]; then return 2; fi
	local get
	get() { drain_config_value "$1"; }
	# shellcheck disable=SC2034
	DRAIN_AGENT=$(get worker.agent)
	DRAIN_MODEL=$(get worker.model)
	DRAIN_OWNER=$(get worker.owner)
	DRAIN_RETRY_FAILED=$(config_get_bool worker.retry_failed 0)
	DRAIN_PERSIST=$(config_get_bool worker.persist 0)
	DRAIN_AUTONOMOUS=$(config_get_bool worker.autonomous 0)
	DRAIN_ALLOW_SUDO=$(config_get_bool worker.allow_sudo 0)
	DRAIN_ALLOW_HOME=$(config_get_bool worker.allow_home 0)
	DRAIN_SKIP_PERMISSIONS=$(config_get_bool worker.skip_permissions 0)
	STALE_AFTER_SEC=$(get worker.stale_after_seconds)
	TASK_TIMEOUT_SEC=$(get worker.task_timeout_seconds)
	DRAIN_PERSIST_POLL_SEC=$(get worker.persist_poll_seconds)
	DRAIN_MIN_WORKERS=$(get supervisor.min_workers)
	DRAIN_MAX_WORKERS=$(get supervisor.max_workers)
	DRAIN_AUTOSCALE_INTERVAL=$(get supervisor.interval_seconds)
	DRAIN_TASKS_PER_WORKER=$(get supervisor.tasks_per_worker)
	DRAIN_STARTUP_LOCK_MAX_AGE_SEC=$(get supervisor.startup_lock_max_age_seconds)
	DRAIN_SYNC_TIMEOUT_SEC=$(get sync.timeout_seconds)
	DRAIN_SYNC_RETRIES=$(get sync.retries)
	DRAIN_SYNC_RETRY_DELAY=$(get sync.retry_delay_seconds)
	DRAIN_LOCK_GRACE_SEC=$(get locks.grace_seconds)
	DRAIN_HISTORY_LIMIT=$(get history.limit)
	DRAIN_WATCH_INTERVAL=$(get display.watch_interval_seconds)
	DRAIN_VERBOSE=$(config_get_bool display.verbose 0)
	local _lvl
	_lvl=$(get logging.level)
	if [ "$_lvl" = "debug" ]; then DRAIN_DEBUG=1; fi
	GIT_ROOT=$(get paths.git_root)
	# Expand leading ~ and $HOME in git_root
	case "$GIT_ROOT" in
	"~"/*) GIT_ROOT="$HOME${GIT_ROOT#\~}" ;;
	"~") GIT_ROOT="$HOME" ;;
	esac
	GIT_ROOT=${GIT_ROOT//\$HOME/$HOME}
	TASK=${TASK:-$(get paths.task_bin)}
	if [ "$TASK" = "task" ] && [ -x /opt/homebrew/bin/task ]; then TASK=/opt/homebrew/bin/task; fi
	OPENCODE_BIN=$(get paths.opencode_bin)
	CLAUDE_BIN=$(get paths.claude_bin)
	CODEX_BIN=$(get paths.codex_bin)
	export DRAIN_AGENT DRAIN_MODEL DRAIN_OWNER DRAIN_RETRY_FAILED DRAIN_PERSIST DRAIN_AUTONOMOUS
	export DRAIN_ALLOW_SUDO DRAIN_ALLOW_HOME DRAIN_SKIP_PERMISSIONS
	export STALE_AFTER_SEC TASK_TIMEOUT_SEC DRAIN_PERSIST_POLL_SEC
	export DRAIN_MIN_WORKERS DRAIN_MAX_WORKERS DRAIN_AUTOSCALE_INTERVAL DRAIN_TASKS_PER_WORKER
	export DRAIN_STARTUP_LOCK_MAX_AGE_SEC DRAIN_SYNC_TIMEOUT_SEC DRAIN_SYNC_RETRIES DRAIN_SYNC_RETRY_DELAY
	export DRAIN_LOCK_GRACE_SEC DRAIN_HISTORY_LIMIT DRAIN_WATCH_INTERVAL DRAIN_VERBOSE
	export GIT_ROOT TASK OPENCODE_BIN CLAUDE_BIN CODEX_BIN
	# TASK_BIN alias for plugin-adjacent consumers (same resolved value)
	TASK_BIN="$TASK"
	export TASK_BIN
}
