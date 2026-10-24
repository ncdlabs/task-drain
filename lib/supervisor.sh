# lib/supervisor.sh — single-instance supervisor guard for task-drain.
# Sourced by `drain` and `task-drain.sh`. Do not run directly.
#
# Model: host-local, advisory state. The supervisor is identified by
# (pidfile PID + process command line), never by PID alone. A PID file
# pointing at a dead process, a non-numeric value, or a live process whose
# command line is not a task-drain supervisor is STALE: it never blocks a
# fresh start and it never authorizes a kill. Only a PID that is alive AND
# whose command line matches the supervisor pattern is treated as live.
#
# Concurrent `drain autoscale` invocations serialize the check-and-launch
# window through an atomic mkdir launch mutex held only during startup
# (milliseconds). The mutex is never held for the supervisor lifetime, so a
# crash cannot leave a permanent lock: a mutex older than
# DRAIN_STARTUP_LOCK_MAX_AGE_SEC (default 120) is treated as stale and
# broken by the next starter.
#
# This guard is host-local. It does not coordinate across machines sharing
# the same TaskChampion pool: two hosts can each run one supervisor. See
# docs/architecture.md.

# Home directory for supervisor state. `drain` exports DRAIN_HOME;
# task-drain.sh only has HOME. Prefer DRAIN_HOME when set.
supervisor_home() {
	if [ -n "${DRAIN_HOME:-}" ]; then printf '%s\n' "$DRAIN_HOME"; else printf '%s/.task-drain\n' "$HOME"; fi
}

supervisor_pidfile() { printf '%s/autoscale.pid\n' "$(supervisor_home)"; }

# Transient launch mutex, held only during check-and-launch.
supervisor_launch_lock() { printf '%s/autoscale.starting\n' "$(supervisor_home)"; }

supervisor_lock_max_age() {
	local v="${DRAIN_STARTUP_LOCK_MAX_AGE_SEC:-120}"
	[[ "$v" =~ ^[0-9]+$ ]] || v=120
	printf '%s\n' "$v"
}

supervisor_registered_pid() {
	local pidfile pid
	pidfile="$(supervisor_pidfile)"
	[ -f "$pidfile" ] || return 1
	pid=$(cat "$pidfile" 2>/dev/null | tr -d ' \t\n' || true)
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$pid"
}

# supervisor_cmd_matches PID — true when PID's command line is a supervisor.
# Requires the literal script name and the autoscale verb so a reused PID
# owned by an unrelated process (sleep, bats, mock task, ...) never matches.
supervisor_cmd_matches() {
	local pid="$1" cmd=""
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
	[ -n "$cmd" ] || return 1
	case "$cmd" in
	*task-drain.sh*autoscale*) return 0 ;;
	*) return 1 ;;
	esac
}

# True when the registered supervisor process is alive and verified.
supervisor_is_live() {
	local pid
	pid=$(supervisor_registered_pid) || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	supervisor_cmd_matches "$pid"
}

# PIDs of supervisor processes other than the registered one (orphans:
# live supervisors with no pidfile, or a pidfile pointing elsewhere).
# Never matches self or ancestors. Prints one PID per line; empty when none.
supervisor_orphan_pids() {
	local skip="$$" p=$PPID ppid guard=0 registered=""
	registered=$(supervisor_registered_pid 2>/dev/null || true)
	while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && [ "$guard" -lt 64 ]; do
		skip="$skip|$p"
		ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
		[[ "$ppid" =~ ^[0-9]+$ ]] || break
		p=$ppid
		guard=$((guard + 1))
	done
	ps -eo pid,command 2>/dev/null |
		awk -v skip="^($skip)$" -v reg="$registered" '
      /[t]ask-drain\.sh/ && /autoscale/ && $1 !~ skip && ($1 != reg || reg == "") {print $1}' || true
}

# Acquire the transient launch mutex. Returns 0 with the mutex held
# (caller must call supervisor_release_launch_lock), 1 when another
# starter is legitimately in progress.
supervisor_acquire_launch_lock() {
	local lock age now mtime max_age
	lock="$(supervisor_launch_lock)"
	mkdir -p "$(supervisor_home)" 2>/dev/null || true
	if mkdir "$lock" 2>/dev/null; then
		printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
		return 0
	fi
	# Mutex exists: break it only when it is clearly stale (older than max).
	max_age=$(supervisor_lock_max_age)
	now=$(date +%s)
	mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
	[[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$now
	age=$((now - mtime))
	if [ "$age" -gt "$max_age" ]; then
		rm -rf "$lock" 2>/dev/null || true
		if mkdir "$lock" 2>/dev/null; then
			printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
			return 0
		fi
	fi
	return 1
}

supervisor_release_launch_lock() {
	local lock
	lock="$(supervisor_launch_lock)"
	[ -d "$lock" ] || return 0
	# Only the holder releases: pid recorded at acquire time must be ours.
	if [ -f "$lock/pid" ]; then
		[ "$(cat "$lock/pid" 2>/dev/null | tr -d ' \t\n')" = "$$" ] || return 0
	fi
	rm -rf "$lock" 2>/dev/null || true
}

# Remove the pidfile only when its content equals $1 (our confirmed PID).
# Never touches a pidfile owned by someone else.
supervisor_remove_pidfile_if() {
	local expect="$1" pidfile current
	pidfile="$(supervisor_pidfile)"
	[ -f "$pidfile" ] || return 0
	current=$(cat "$pidfile" 2>/dev/null | tr -d ' \t\n' || true)
	[ "$current" = "$expect" ] || return 1
	rm -f "$pidfile" 2>/dev/null || true
}
