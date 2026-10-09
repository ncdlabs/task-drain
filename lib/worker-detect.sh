# lib/worker-detect.sh — shared worker detection functions for task-drain
# Sourced by task-drain.sh and drain. Do not run directly.

# Get PIDs of running task-drain.sh workers (newest first).
# Never matches self or ancestors (a caller whose own command line names the
# worker script is not a worker).
drain_worker_pids() {
	local skip="$$" p=$PPID ppid guard=0
	while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && [ "$guard" -lt 64 ]; do
		skip="$skip|$p"
		ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
		[[ "$ppid" =~ ^[0-9]+$ ]] || break
		p=$ppid
		guard=$((guard + 1))
	done
	ps -eo pid,command 2>/dev/null |
		awk -v skip="^($skip)$" '/(^|[^A-Za-z0-9_-])[t]ask-drain\.sh/ && !/ status/ && !/ watch/ && !/ workers/ && $1 !~ skip {print $1}' |
		sort -rn || true
}

# Get worker info: pid, etime, command (one per line, tab-separated).
# Used by cmd_status() for the detailed worker view.
drain_worker_info() {
	local skip="$$" p=$PPID ppid guard=0
	while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && [ "$guard" -lt 64 ]; do
		skip="$skip|$p"
		ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
		[[ "$ppid" =~ ^[0-9]+$ ]] || break
		p=$ppid
		guard=$((guard + 1))
	done
	ps -eo pid,ppid,etime,command 2>/dev/null |
		awk -v skip="^($skip)$" '/(^|[^A-Za-z0-9_-])[t]ask-drain\.sh/ && !/ status/ && !/ watch/ && !/ workers/ && $1 !~ skip { pid=$1; ppid=$2; pids[pid]=1; parent[pid]=ppid; et[pid]=$3; $1=$2=$3=""; sub(/^   */, ""); cmd[pid]=$0; next } END { for (p in pids) if (!(parent[p] in pids)) print p, et[p], cmd[p] }' | sort -n || true
}
