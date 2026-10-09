#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:/Users/lou/.opencode/bin:/Users/lou/bin:/usr/bin:/bin:/usr/sbin:/sbin  # llama Mac tool paths
#
# task-drain.sh -- autonomous drain worker for the shared Taskwarrior pool.
#
# COMMANDS:
#   bash bin/task-drain.sh          # run a drain worker (drains until empty)
#   bash bin/task-drain.sh status  # show workers, kill switch, queue state
#
# WORKER LOOP: sync -> release stale claims -> pick highest-urgency eligible
# task -> claim it -> run `opencode run` on it -> verify -> repeat until empty.
#
# (Run with `bash`; the file may not carry the exec bit, and `bash script`
#  doesn't need it.)
#
# Run 2-3 copies in separate terminals for a worker pool. The pick->claim
# window is ~100ms; a rare double-claim just means two agents annotate the
# same task, not corruption. Claims are released on completion or failure.
#
# STOPPING:
#   Graceful (workers finish nothing new; in-flight task runs to completion,
#   then the worker exits):
#       touch ~/.task-drain/STOP
#   Immediate (kills workers mid-task; the in-flight task is released back
#   to pending, cleanly):
#       pkill -TERM -f task-drain.sh
#   Resume: rm ~/.task-drain/STOP   then start workers again.
#
# ELIGIBILITY: pending, not active, not waiting, not blocked, and NOT tagged:
#   noauto        -- opt out of autonomous pickup (tag any task to skip it)
#   drain-failed  -- set automatically when a worker attempt ends without the
#                    task being completed; clear it to re-queue:
#                      /opt/homebrew/bin/task <uuid> modify -drain-failed
#
# RETRY MODE (DRAIN_RETRY_FAILED=1):
#   Workers reprocess drain-failed tasks instead of the regular queue.
#   The failed set is snapshotted at worker start; each task is retried at
#   most once per run, so a task that fails again can't loop -- it keeps
#   drain-failed for the next explicit retry. Launched via:
#     drain start [N] [project] --failed
#
# SAFETY DIALS:
#   OPENCODE_RUN_FLAGS -- default --dangerously-skip-permissions --model
#     opencode-go/longcat-2.5-preview-free. Without --dangerously-skip-permissions
#     an unattended run stalls on the first approval prompt; with it the agent can
#     edit, run, and push without asking. This is the main risk dial. The model
#     is pinned to the only zero-cost model on the opencode-go provider (all other
#     opencode-go models are paid). Verify flags with: opencode run --help
#     WARNING: an invalid flag here fails EVERY task attempt, and each failure
#     is failed as +drain-failed -- one bad flag can drain-fail the whole queue
#     (and workers then exit on the empty eligible set). Test a single task
#     after changing flags. Working directory is set via subshell cd because
#     `opencode run` accepts no --dir flag.
#   STALE_AFTER_SEC  -- drain-claimed tasks active longer than this with no
#     completion are released back to the pool (only tasks THIS script claimed;
#     interactive agents' active tasks are never touched).
#   TASK_TIMEOUT_SEC -- per-task wall clock, only if `gtimeout` (coreutils) is
#     installed. Timed-out tasks are failed, not retried.
#
# The worker prompt forbids the agent from deciding design / security / product
# matters (those belong to Lou + Juno): it must annotate and fail instead.
#
set -euo pipefail

TASK=/opt/homebrew/bin/task
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
OPENCODE_RUN_FLAGS=(--standalone --dangerously-skip-permissions --model opencode-go/longcat-2.5-preview-free)
STALE_AFTER_SEC="${STALE_AFTER_SEC:-14400}"   # 4 hours
TASK_TIMEOUT_SEC="${TASK_TIMEOUT_SEC:-14400}" # 4 hours per task (gtimeout only)
PROJECT_FILTER="${PROJECT_FILTER:-}"
DRAIN_RETRY_FAILED="${DRAIN_RETRY_FAILED:-0}" # 1 = reprocess drain-failed tasks instead of the regular queue
RETRY_SNAPSHOT=""                             # temp file holding retry UUIDs for this run
GIT_ROOT="$HOME/git"
STOP_FILE="$HOME/.task-drain/STOP"
WORKER_ID="drain-$(hostname -s)-$$"
CHILD_PID=""
CURRENT_UUID=""

log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$WORKER_ID" "$*" >&2; }

stop_requested() { [ -e "$STOP_FILE" ] || [ -e "${STOP_FILE}.$$" ]; }

stop_scope() { # why this worker is stopping: global|personal|none
	if [ -e "$STOP_FILE" ]; then
		echo global
	elif [ -e "${STOP_FILE}.$$" ]; then
		echo personal
	else echo none; fi
}

claim_task() { # $1 = uuid
	$TASK "$1" modify +drain-claimed >/dev/null
	if [ "$DRAIN_RETRY_FAILED" = "1" ]; then
		$TASK "$1" modify -drain-failed >/dev/null
		$TASK "$1" annotate "drain worker $WORKER_ID retrying previously failed attempt ($(date -u +%Y-%m-%dT%H:%M:%SZ))" >/dev/null
	else
		$TASK "$1" annotate "claimed by $WORKER_ID at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
	fi
	$TASK "$1" start >/dev/null
	$TASK sync >/dev/null
}

release_claim() { # $1 = uuid, $2 = reason annotation
	$TASK "$1" modify -drain-claimed >/dev/null || true
	$TASK "$1" annotate "$2" >/dev/null || true
	$TASK "$1" stop >/dev/null || true
}

cleanup_retry() { [ -n "$RETRY_SNAPSHOT" ] && rm -f "$RETRY_SNAPSHOT" "$RETRY_SNAPSHOT.tmp"; }

on_signal() {
	log "signal received; stopping worker and child ${CHILD_PID:-none}"
	if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null || true; fi
	if [ -n "$CURRENT_UUID" ]; then
		release_claim "$CURRENT_UUID" "drain worker $WORKER_ID: stopped by signal; claim released, task left pending" || true
		$TASK sync >/dev/null || true
	fi
	rm -f "${STOP_FILE}.$$"
	cleanup_retry
	exit 130
}
trap on_signal INT TERM

repo_for_project() {
	case "${1:-}" in
	attendeesync) echo "$GIT_ROOT/attendeesync" ;;
	ncdlabs) echo "$GIT_ROOT/ncdlabs.com" ;;
	ncdlabs-assure) echo "$GIT_ROOT/ncdlabs-assure" ;;
	ncdlabs-changepress) echo "$GIT_ROOT/ncdlabs-changepress" ;;
	ncdlabs-site-access-policies) echo "$GIT_ROOT/ncdlabs-site-access-policies" ;;
	agentx) echo "$GIT_ROOT/agentx" ;;
	innercircles) echo "$GIT_ROOT/innercircles" ;;
	gitseer) echo "$GIT_ROOT/gitseer" ;;
	meridian) echo "$GIT_ROOT/meridian" ;;
	solfoundation) echo "$GIT_ROOT/wp-solfoundation-plugin" ;;
	*) echo "" ;;
	esac
}

pick_task() {
	if [ "$DRAIN_RETRY_FAILED" = "1" ]; then
		pick_retry_task
		return
	fi
	local filter="+PENDING -ACTIVE -WAITING -BLOCKED -noauto -drain-failed"
	if [ -n "$PROJECT_FILTER" ]; then filter="project:$PROJECT_FILTER $filter"; fi
	# shellcheck disable=SC2086
	$TASK $filter export 2>/dev/null | jq -c 'sort_by(.urgency // 0) | reverse | .[0] // empty'
}

# Retry mode: pop UUIDs off the startup snapshot. Each failed task is retried
# at most once per run -- a task that fails again keeps drain-failed but is
# already consumed from the snapshot, so it can't loop forever.
pick_retry_task() {
	local uuid ok
	while [ -s "$RETRY_SNAPSHOT" ]; do
		uuid=$(head -n 1 "$RETRY_SNAPSHOT")
		tail -n +2 "$RETRY_SNAPSHOT" >"$RETRY_SNAPSHOT.tmp" && mv "$RETRY_SNAPSHOT.tmp" "$RETRY_SNAPSHOT"
		[ -n "$uuid" ] || continue
		ok=$($TASK "$uuid" export 2>/dev/null | jq -r '.[0] | select(.status=="pending" and ((.tags//[]) | index("drain-failed")) and (.start|not)) | .uuid // empty')
		if [ -n "$ok" ]; then
			$TASK "$uuid" export 2>/dev/null | jq -c '.[0]'
			return 0
		fi
		log "retry: skipping $uuid (no longer failed/pending/idle)"
	done
	return 1
}

reclaim_stale() {
	local cutoff=$(($(date +%s) - STALE_AFTER_SEC))
	$TASK +drain-claimed +ACTIVE export 2>/dev/null |
		jq -r --argjson cutoff "$cutoff" \
			'.[] | select(.start and ((.start | strptime("%Y%m%dT%H%M%SZ") | mktime) < $cutoff)) | .uuid' |
		while IFS= read -r uuid; do
			[ -n "$uuid" ] || continue
			log "releasing stale claim: $uuid"
			release_claim "$uuid" "drain worker: released stale claim (active > $((STALE_AFTER_SEC / 3600))h, no completion)"
		done || true
	$TASK sync >/dev/null || true
}

build_prompt() { # $1 uuid $2 project $3 priority $4 description $5 annotations $6 repo
	cat <<PROMPT_EOF
You are an autonomous coding-agent worker on Lou's Mac. Work exactly ONE Taskwarrior task to completion, then stop. Do not pick up other tasks.

TASK
  UUID:        $1   <- always reference tasks by UUID, never short numeric IDs
  Project:     $2
  Priority:    $3
  Description: $4
  Annotations:
$5

ENVIRONMENT
- macOS. Repos live under /Users/lou/git. Your working directory is: $6
- Taskwarrior binary: /opt/homebrew/bin/task (use this exact full path; it talks to the shared TaskChampion pool)
- 'git pull --rebase' before starting. Never force-push. Never change the task sync client ID.

DISCIPLINE (non-negotiable)
- Taskwarrior is the only system of record. Run '/opt/homebrew/bin/task sync' at session start, after every change, and at session end.
- If sync fails: stop, annotate the failure on the task, report it, do not continue offline.
- Keep annotations current as you work. Search for duplicates before creating any task.
- Durable decisions go in the repo's docs/DECISIONS.md, not in tasks.

AUTHORITY (non-negotiable)
- Design, security, product, and public-facing decisions belong to Lou and Juno. You do not make them.
- If this task needs human judgment, credentials you do not have, a legal/compliance declaration, publishing or submitting anything public, or any irreversible action beyond the task's stated scope: DO NOT complete it. Annotate exactly what is needed and by whom, run '/opt/homebrew/bin/task $1 stop', sync, and print FAILED: <reason> as your final line.

COMPLETION CONTRACT
- Do the work. Verify it for real: run the build, the tests, or the task's own acceptance criteria. Never assert success you did not observe.
- Only when the acceptance criteria are truly met: annotate a short summary of what changed, run '/opt/homebrew/bin/task $1 done', sync, and print DONE: <one-line summary> as your final line.
- If you cannot meet the criteria: annotate the precise blocker, run '/opt/homebrew/bin/task $1 stop' (leave it pending), sync, and print FAILED: <reason>. Never mark done on partial or unverified work.

GIT WORKFLOW (when the task involves code changes)
- Work on a feature branch, never directly on main/master. If not already on a branch, create one: git checkout -b <task-desc-short>
- Commit your changes with a clear message referencing the task UUID.
- Push the branch: git push -u origin <branch-name>
- Create a PR and leave it open for Lou to review. Never merge it yourself.
  - For Gitea repos (git.ncdlabs.com): use the gitea-mcp-server tools if available, or the API:
    curl -s -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
      -d '{"title":"<task description>","head":"<branch>","base":"main","body":"Task <uuid>. <summary>"}' \
      https://git.ncdlabs.com/api/v1/repos/<owner>/<repo>/pulls
    (GITEA_TOKEN is in ~/.zshenv and works in non-interactive shells.)
  - For GitHub repos: gh pr create --title "<task description>" --body "Task <uuid>. <summary>"
- If push or PR creation fails (auth not set up, etc.): annotate the blocker on the task, print FAILED: <reason>, do not mark done.
PROMPT_EOF
}

run_one() { # $1 = task export JSON
	local uuid project priority description annotations repo prompt rc status
	uuid=$(jq -r '.uuid' <<<"$1")
	project=$(jq -r '.project // "(none)"' <<<"$1")
	priority=$(jq -r '.priority // "(none)"' <<<"$1")
	description=$(jq -r '.description' <<<"$1")
	annotations=$(jq -r '(.annotations // []) | map(.description) | join("\n")' <<<"$1")
	[ -n "$annotations" ] || annotations="(none)"
	repo=$(repo_for_project "$project")
	if [ -z "$repo" ] || [ ! -d "$repo" ]; then repo="$HOME"; fi

	log "starting: [$project] $description ($uuid)"
	claim_task "$uuid"
	CURRENT_UUID="$uuid"
	prompt=$(build_prompt "$uuid" "$project" "$priority" "$description" "$annotations" "$repo")

	# Background progress annotator: updates task with current file/operation
	annotate_progress() {
		local note=""
		if [ -d "$repo/.git" ]; then
			note=$(cd "$repo" && git status --porcelain 2>/dev/null | head -3 | sed 's/^.. //' | tr '\n' ';' | sed 's/;$//')
			[ -z "$note" ] && note=$(cd "$repo" && ls -t *.go *.ts *.py *.sh *.js *.json *.md 2>/dev/null | head -1)
		fi
		[ -z "$note" ] && note="working..."
		$TASK "$uuid" annotate "progress: $note" >/dev/null 2>&1 || true
	}

	rc=0
	# NOTE: `opencode run` has no --dir flag (v2.0.24 takes no directory flag;
	# verify with: opencode run --help). Set the working directory via subshell
	# cd instead -- a bad flag here fails every task and mass-fails the queue
	# as +drain-failed without doing any work.
	if command -v gtimeout >/dev/null 2>&1; then
		(cd "$repo" && exec gtimeout "$TASK_TIMEOUT_SEC" "$OPENCODE_BIN" run "${OPENCODE_RUN_FLAGS[@]}" "$prompt" < /dev/null) &
	else
		(cd "$repo" && exec "$OPENCODE_BIN" run "${OPENCODE_RUN_FLAGS[@]}" "$prompt" < /dev/null) &
	fi
	CHILD_PID=$!

	# Run annotator every 30s in background (after CHILD_PID is set)
	(while kill -0 "$CHILD_PID" 2>/dev/null; do
		sleep 30
		annotate_progress
	done) &
	ANNOTATOR_PID=$!

	wait "$CHILD_PID" || rc=$?
	CHILD_PID=""

	# Stop annotator
	kill "$ANNOTATOR_PID" 2>/dev/null || true
	wait "$ANNOTATOR_PID" 2>/dev/null || true

	$TASK sync >/dev/null || true
	status=$($TASK "$uuid" export 2>/dev/null | jq -r '.[0].status // "unknown"')
	CURRENT_UUID=""
	if [ "$status" = "completed" ]; then
		log "DONE: [$project] $description"
		return 0
	fi
	log "not completed (agent rc=$rc, status=$status) -- failed, will not auto-retry"
	$TASK "$uuid" modify +drain-failed >/dev/null || true
	release_claim "$uuid" "drain worker $WORKER_ID: agent exited (rc=$rc) without completing; tagged drain-failed, not auto-retried"
	$TASK sync >/dev/null || true
	return 1
}

run_worker() {
	command -v "$OPENCODE_BIN" >/dev/null 2>&1 || {
		log "ERROR: '$OPENCODE_BIN' not found on PATH"
		exit 1
	}
	command -v jq >/dev/null 2>&1 || {
		log "ERROR: jq not found (brew install jq)"
		exit 1
	}
	[ -x "$TASK" ] || {
		log "ERROR: $TASK not executable"
		exit 1
	}
	mkdir -p "$(dirname "$STOP_FILE")"
	if stop_requested; then
		log "STOP file present ($STOP_FILE); refusing to start"
		exit 0
	fi
	log "worker starting (filter: ${PROJECT_FILTER:-all projects})"
	$TASK sync || {
		log "ERROR: initial sync failed -- aborting, never work offline"
		exit 1
	}

	# Retry mode: snapshot the failed set once; each task gets at most one
	# retry per run, so a task that fails again can't loop forever.
	local done_msg="queue drained"
	if [ "$DRAIN_RETRY_FAILED" = "1" ]; then
		done_msg="failed set reprocessed"
		RETRY_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/drain-retry.XXXXXX")
		local rfilter="+drain-failed -ACTIVE -WAITING -BLOCKED -noauto"
		if [ -n "$PROJECT_FILTER" ]; then rfilter="project:$PROJECT_FILTER $rfilter"; fi
		# shellcheck disable=SC2086
		$TASK $rfilter export 2>/dev/null | jq -r '.[].uuid' >"$RETRY_SNAPSHOT"
		local rcount
		rcount=$(grep -c . "$RETRY_SNAPSHOT" || true)
		if [ "$rcount" = "0" ]; then
			log "retry mode: no failed tasks to reprocess${PROJECT_FILTER:+ [project=$PROJECT_FILTER]}. exiting."
			cleanup_retry
			exit 0
		fi
		log "retry mode: $rcount failed task(s) to reprocess${PROJECT_FILTER:+ [project=$PROJECT_FILTER]}"
	fi

	local completed=0 failed=0 task_json scope
	while true; do
		if stop_requested; then
			scope=$(stop_scope)
			log "STOP requested ($scope); exiting without picking up new tasks."
			rm -f "${STOP_FILE}.$$"
			cleanup_retry
			$TASK sync >/dev/null || true
			exit 0
		fi
		reclaim_stale
		task_json=$(pick_task) || task_json=""
		if [ -z "$task_json" ]; then
			$TASK sync >/dev/null || true
			log "$done_msg -- completed=$completed failed=$failed. exiting."
			rm -f "${STOP_FILE}.$$"
			cleanup_retry
			exit 0
		fi
		if run_one "$task_json"; then completed=$((completed + 1)); else failed=$((failed + 1)); fi
	done
}

cmd_status() {
	[ -x "$TASK" ] || {
		echo "ERROR: $TASK not executable" >&2
		exit 1
	}
	command -v jq >/dev/null 2>&1 || {
		echo "ERROR: jq not found (brew install jq)" >&2
		exit 1
	}

	# --- terminal setup: color only on a TTY, respect NO_COLOR ---
	local use_color=0
	if [ -n "${DRAIN_FORCE_COLOR:-}" ] && [ -z "${NO_COLOR:-}" ]; then
		use_color=1
	elif [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then use_color=1; fi
	local B="" C="" G="" Y="" R="" M="" DIM="" RESET=""
	if [ "$use_color" = 1 ]; then
		B=$'\033[1m'
		C=$'\033[36m'
		G=$'\033[32m'
		Y=$'\033[33m'
		R=$'\033[31m'
		M=$'\033[35m'
		DIM=$'\033[2m'
		RESET=$'\033[0m'
	fi
	local cols
	cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	[[ "$cols" =~ ^[0-9]+$ ]] || cols=80
	[ "$cols" -ge 40 ] || cols=40
	[ "$cols" -le 200 ] || cols=200

	divider() {
		local i
		for ((i = 0; i < cols; i++)); do printf '─'; done
		printf '\n'
	}
	section() { printf '\n%s%s%s%s%s\n' "$B" "$C" "$1" "$RESET" ""; }
	trunc_str() { # $1=text $2=maxlen
		local s="$1" max="$2"
		if [ "${#s}" -gt "$max" ]; then printf '%s…' "${s:0:$((max - 1))}"; else printf '%s' "$s"; fi
	}
	bar() { # $1=n $2=max $3=width
		local n="$1" max="$2" width="${3:-18}" fill empty i
		[[ "$n" =~ ^[0-9]+$ ]] || n=0
		[[ "$max" =~ ^[0-9]+$ ]] || max=1
		[ "$max" -ge 1 ] || max=1
		fill=$((n * width / max))
		[ "$fill" -gt "$width" ] && fill=$width
		empty=$((width - fill))
		for ((i = 0; i < fill; i++)); do printf '█'; done
		for ((i = 0; i < empty; i++)); do printf '░'; done
	}

	# Optional project scoping (`drain status <project>` sets PROJECT_FILTER).
	# tq = task query with the scope applied; plain $TASK stays global (sync).
	tq() {
		if [ -n "${PROJECT_FILTER:-}" ]; then
			"$TASK" "project:${PROJECT_FILTER}" "$@"
		else
			"$TASK" "$@"
		fi
	}

	# --- sync (skipped on watch refreshes; first frame syncs) ---
	local sync_state="${DIM}sync: ok${RESET}"
	if [ -n "${DRAIN_NO_SYNC:-}" ]; then
		sync_state="${DIM}sync: watch (no re-sync)${RESET}"
	elif ! $TASK sync >/dev/null 2>&1; then sync_state="${Y}sync: FAILED (showing local state)${RESET}"; fi

	# --- workers (portable ps; macOS pgrep lacks -c/-a-print) ---
	# Never match self or ancestors (a status probe's own command line
	# names the worker script).
	local worker_ps nworkers _skip="$$" _p=$PPID _ppid _guard=0
	while [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -gt 1 ] && [ "$_guard" -lt 64 ]; do
		_skip="$_skip|$_p"
		_ppid=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || true)
		[[ "$_ppid" =~ ^[0-9]+$ ]] || break
		_p=$_ppid
		_guard=$((_guard + 1))
	done
	worker_ps=$(ps -eo pid,ppid,etime,command 2>/dev/null |
		awk -v skip="^($_skip)$" '/(^|[^A-Za-z0-9_-])[t]ask-drain\.sh/ && !/ status/ && !/ watch/ && !/ workers/ && $1 !~ skip { pid=$1; ppid=$2; pids[pid]=1; parent[pid]=ppid; et[pid]=$3; $1=$2=$3=""; sub(/^   */, ""); cmd[pid]=$0; next } END { for (p in pids) if (!(parent[p] in pids)) print p, et[p], cmd[p] }' | sort -n || true)
	if [ -z "$worker_ps" ]; then nworkers=0; else nworkers=$(printf '%s\n' "$worker_ps" | wc -l | tr -d ' '); fi
	[[ "$nworkers" =~ ^[0-9]+$ ]] || nworkers=0

	# --- kill switch ---
	local ks_txt ks_dot
	if stop_requested; then
		ks_dot="${R}■ STOPPED${RESET}"
		ks_txt="STOP file present ($STOP_FILE)"
	else
		ks_dot="${G}● LIVE${RESET}"
		ks_txt="accepting work"
	fi

	# --- queue counts, pending-scoped to match the tagging system (see `drain docs`) ---
	# Eligibility == pick_task(): +PENDING -ACTIVE -WAITING -BLOCKED -noauto -drain-failed.
	# Tag counts are scoped to +PENDING so completed/deleted tasks with stale
	# tags never inflate the dashboard. Exception: +WAITING is disjoint from
	# +PENDING in this Taskwarrior version (+PENDING +WAITING is always 0), so
	# the Waiting count is global by necessity -- those are the scheduled-future
	# tasks pickup skips. (-WAITING in the pickup filter is then a no-op kept
	# for clarity.)
	local n_elig n_active n_blocked n_waiting n_noauto n_failed n_done
	local n_claimed n_claimed_active n_interactive n_stale n_pending_total
	n_elig=$(tq +PENDING -ACTIVE -WAITING -BLOCKED -noauto -drain-failed count 2>/dev/null || echo "?")
	n_active=$(tq +ACTIVE count 2>/dev/null || echo "?")
	n_blocked=$(tq +PENDING +BLOCKED count 2>/dev/null || echo "?")
	n_waiting=$(tq +WAITING count 2>/dev/null || echo "?")
	n_noauto=$(tq +PENDING +noauto count 2>/dev/null || echo "?")
	n_failed=$(tq +PENDING +drain-failed count 2>/dev/null || echo "?")
	n_claimed_active=$(tq +ACTIVE +drain-claimed count 2>/dev/null || echo "?")
	n_done=$(tq +COMPLETED end.after:today count 2>/dev/null || echo "?")
	n_pending_total=$(tq +PENDING count 2>/dev/null || echo "?")
	# Interactive active = total active minus worker-claimed active.
	if [[ "$n_active" =~ ^[0-9]+$ ]] && [[ "$n_claimed_active" =~ ^[0-9]+$ ]]; then
		n_interactive=$((n_active - n_claimed_active))
	else
		n_interactive="?"
	fi
	# Stale worker claims (would be released by reclaim_stale on the next loop).
	n_stale=0
	{
		local cutoff
		cutoff=$(($(date +%s) - STALE_AFTER_SEC))
		n_stale=$(tq +drain-claimed +ACTIVE export 2>/dev/null |
			jq --argjson cutoff "$cutoff" \
				'[.[] | select(.start and ((.start | strptime("%Y%m%dT%H%M%SZ") | mktime) < $cutoff))] | length' 2>/dev/null || echo "?")
	}

	# --- data exports (single shot each; tag exports scoped to +PENDING) ---
	local eligible_json active_json failed_json
	eligible_json=$(tq +PENDING -ACTIVE -WAITING -BLOCKED -noauto -drain-failed export 2>/dev/null || echo '[]')
	active_json=$(tq +ACTIVE export 2>/dev/null || echo '[]')
	failed_json=$(tq +PENDING +drain-failed export 2>/dev/null || echo '[]')

	local desc_max=$((cols - 34))
	[ "$desc_max" -ge 30 ] || desc_max=30
	[ "$desc_max" -le 90 ] || desc_max=90

	# ================= header =================
	printf '%sDRAIN STATUS%s  %s  ·  %s · %s\n' "$B" "$RESET" "$(date '+%a %F %T %Z')" "$sync_state" "$ks_dot"
	if [ -n "${PROJECT_FILTER:-}" ]; then printf '  scope: project=%s\n' "$PROJECT_FILTER"; fi
	if [ -n "${PROJECT_FILTER:-}" ] && [ "${n_pending_total:-}" = "0" ]; then
		printf '  %s(no pending tasks in project %s — check the name with: task _projects)%s\n' "$DIM" "$PROJECT_FILTER" "$RESET"
	fi
	divider

	local verbose=0
	[ "${DRAIN_VERBOSE:-0}" = "1" ] && verbose=1
	local list_max=8 fail_max=3
	if [ "$verbose" = 1 ]; then
		list_max=999999
		fail_max=999999
	fi

	dur() { # seconds -> 45s / 12m / 3h / 15d / ?
		local s="$1"
		[[ "$s" =~ ^[0-9]+$ ]] || {
			printf '?'
			return
		}
		if [ "$s" -lt 90 ]; then
			printf '%ss' "$s"
		elif [ "$s" -lt 5400 ]; then
			printf '%sm' "$((s / 60))"
		elif [ "$s" -lt 172800 ]; then
			printf '%sh' "$((s / 3600))"
		else printf '%sd' "$((s / 86400))"; fi
	}

	# --- attention model: one pass over active tasks ---
	# Owner pid comes from the LAST claim-or-retry note, so retried tasks
	# point at their live worker instead of looking orphaned.
	local stale_after="${STALE_AFTER_SEC:-14400}"
	[[ "$stale_after" =~ ^[0-9]+$ ]] || stale_after=14400
	local now live_json attn_json
	now=$(date +%s)
	live_json=$(printf '%s\n' "$worker_ps" | awk 'NF{print $1}' | jq -R . | jq -s . 2>/dev/null || echo '[]')
	attn_json=$(printf '%s' "$active_json" | jq --argjson live "$live_json" --argjson now "$now" \
		--argjson stale_after "$stale_after" '
    [.[] |
      (.annotations // []) as $anns |
      ([$anns[]?.description | select(test("claimed by drain-|retrying previously failed"))] | last // "") as $own |
      ((if $own == "" then {pid:"?"} else ($own | capture("-(?<pid>[0-9]+)( at| retrying)") // {pid:"?"}) end) | .pid) as $pid |
      {
        uuid: (.uuid // "?"),
        short: ((.uuid // "?") | .[0:8]),
        project: (.project // "-"),
        desc: ((.description // "?") | gsub("[\t\n]"; " ")),
        pri: (.priority // "-"),
        start: (.start // "?"),
        drain: (if ((.tags // []) | index("drain-claimed")) then true else false end),
        failed: (if ((.tags // []) | index("drain-failed")) then true else false end),
        pid: $pid,
        elapsed: (if .start then try (($now - (.start | strptime("%Y%m%dT%H%M%SZ") | mktime)) | floor) catch -1 else -1 end),
        quiet: ([($anns[]? | .entry | select(. != null) | try (strptime("%Y%m%dT%H%M%SZ") | mktime) catch empty)] | if length > 0 then ($now - max | floor) else -1 end),
        prog: ([$anns[]? | .description | select(startswith("progress:"))] | if length > 0 then (last | sub("^progress: "; "") | gsub("[\t\n]"; " ")) else "" end)
      }
      | .stale = (.drain and .elapsed >= 0 and .elapsed > $stale_after)
      | .orphan = (.drain and $pid != "?" and (($live | index($pid)) | not))
      | .unlinked = (.drain and $pid == "?")
      | .stuck = (.drain and .failed)
      | .manual_idle = ((.drain | not) and .quiet > 172800)
      | .rank = (if .orphan then 0 elif .stuck then 1 elif .unlinked then 2 elif .stale then 3 else 4 end)
      | .flags = ([(if .orphan then "orphan" else empty end), (if .stuck then "stuck" else empty end), (if .unlinked then "unlinked" else empty end), (if (.stale and ((.orphan or .stuck) | not)) then "stale" else empty end), (if .manual_idle then "manual-idle" else empty end)] | join("+"))
    ]' 2>/dev/null || echo '[]')

	# ================= workers =================
	local nWork=0 nIdle=0
	nWork=$(printf '%s' "$attn_json" | jq --argjson live "$live_json" '[.[] | select(.drain) | .pid as $p | select($p != "?" and ($live | index($p))) | $p] | unique | length' 2>/dev/null || echo 0)
	[[ "$nWork" =~ ^[0-9]+$ ]] || nWork=0
	nIdle=$((nworkers - nWork))
	[ "$nIdle" -ge 0 ] || nIdle=0
	if [ "$nworkers" -gt 0 ]; then
		if [ -n "${PROJECT_FILTER:-}" ]; then
			printf 'Workers: %s%d running%s (%d on %s · %d other/idle)\n' "$B" "$nworkers" "$RESET" "$nWork" "$PROJECT_FILTER" "$nIdle"
		else
			printf 'Workers: %s%d running%s (%d on tasks · %d idle)\n' "$B" "$nworkers" "$RESET" "$nWork" "$nIdle"
		fi
		if [ "$verbose" = 1 ]; then
			local _wline _pid _etime _cmd _task _mark
			while IFS= read -r _wline; do
				[ -n "$_wline" ] || continue
				_pid=$(awk '{print $1}' <<<"$_wline")
				_etime=$(awk '{print $2}' <<<"$_wline")
				_cmd=$(awk '{$1=""; $2=""; sub(/^  */, ""); if (length($0)>60) $0=substr($0,1,59)"…"; print}' <<<"$_wline")
				_task=$(printf '%s' "$attn_json" | jq -r --arg pid "$_pid" '[.[] | select(.drain and .pid == $pid)] | .[0] | if . then "\(.project) / \(.desc | .[0:60])" else "idle" end' 2>/dev/null || true)
				_mark=""
				if [ -e "$STOP_FILE" ] || [ -e "${STOP_FILE}.${_pid}" ]; then _mark=" ${Y}(stopping)${RESET}"; fi
				printf '  ○ pid %-7s [%s] %s → %s%s\n' "$_pid" "$_etime" "$_cmd" "$_task" "$_mark"
			done <<<"$worker_ps"
		fi
	else
		printf 'Workers: %snone running%s (start with: drain start 2 [project])\n' "$DIM" "$RESET"
	fi

	# ================= queue =================
	printf 'Queue: %s%s ready%s of %s pending · %s in progress (%s drain · %s manual) · %s%s failed%s · %s done today\n' \
		"$B" "$n_elig" "$RESET" "$n_pending_total" "$n_active" "$n_claimed_active" "$n_interactive" "$Y" "$n_failed" "$RESET" "$n_done"
	if [ "$verbose" = 1 ]; then
		printf '  %sblocked %s · waiting %s · opted out %s · stale claims %s%s\n' "$DIM" "$n_blocked" "$n_waiting" "$n_noauto" "$n_stale" "$RESET"
	fi

	# ================= next =================
	local next_one _np _npri _nurg _ndesc
	next_one=$(printf '%s' "$eligible_json" | jq -r 'sort_by(.urgency // 0) | reverse | .[0] | if . then "\(.project // "-")\t\(.priority // "-")\t\(.urgency // 0)\t\((.description // "?") | gsub("[\t\n]"; " "))" else "" end' 2>/dev/null || true)
	if [ -n "$next_one" ]; then
		IFS=$'\t' read -r _np _npri _nurg _ndesc <<<"$next_one"
		printf 'Next: [%s] (%s) %s %s(urg %s)%s\n' "$_np" "$_npri" "$(trunc_str "$_ndesc" "$desc_max")" "$DIM" "$_nurg" "$RESET"
		if [ "$verbose" = 1 ]; then
			printf '%s' "$eligible_json" | jq -r 'sort_by(.urgency // 0) | reverse | .[1:5] | .[] | "\(.project // "-")\t\(.priority // "-")\t\(.urgency // 0)\t\((.description // "?") | gsub("[\t\n]"; " "))"' 2>/dev/null |
				while IFS=$'\t' read -r _np _npri _nurg _ndesc; do
					[ -n "$_ndesc" ] || continue
					printf '      [%s] (%s) %s %s(urg %s)%s\n' "$_np" "$_npri" "$(trunc_str "$_ndesc" "$desc_max")" "$DIM" "$_nurg" "$RESET"
				done || true
		fi
	else
		printf 'Next: %snothing ready%s — %s blocked · %s started · %s opted out · %s failed · %s waiting\n' \
			"$DIM" "$RESET" "$n_blocked" "$n_active" "$n_noauto" "$n_failed" "$n_waiting"
	fi

	# ================= in progress =================
	local prog_tsv _ptotal
	prog_tsv=$(printf '%s' "$attn_json" | jq -r 'sort_by(.elapsed) | reverse | .[] | "\(.drain)\t\(.project)\t\(.desc)\t\(.prog)\t\(.elapsed)\t\(.quiet)\t\(.short)"' 2>/dev/null || true)
	_ptotal=$(printf '%s' "$prog_tsv" | grep -c . || true)
	if [ -n "$prog_tsv" ]; then
		printf '%sIn progress%s\n' "$B" "$RESET"
		local _shown=0 _pdr _pproj _pdesc _pprog _pel _pq _pshort _pline
		while IFS=$'\t' read -r _pdr _pproj _pdesc _pprog _pel _pq _pshort; do
			[ -n "$_pdesc" ] || continue
			_shown=$((_shown + 1))
			if [ "$_shown" -gt "$list_max" ]; then
				printf '  %s… +%d more (use --verbose)%s\n' "$DIM" "$((_ptotal - list_max))" "$RESET"
				break
			fi
			if [ "$_pdr" = "true" ]; then
				if [ -n "$_pprog" ]; then _pline="→ $_pprog"; else _pline="quiet $(dur "$_pq")"; fi
				printf '  %s●%s [%s] %s  %s%s (%s)%s\n' "$C" "$RESET" "$_pproj" "$(trunc_str "$_pdesc" "$desc_max")" "$DIM" "$(trunc_str "$_pline" 60)" "$(dur "$_pel")" "$RESET"
			else
				printf '  %s○ manual%s [%s] %s  %sstarted %s ago · quiet %s%s\n' "$M" "$RESET" "$_pproj" "$(trunc_str "$_pdesc" "$desc_max")" "$DIM" "$(dur "$_pel")" "$(dur "$_pq")" "$RESET"
			fi
		done <<<"$prog_tsv"
	fi

	# ================= needs attention =================
	local attn_tsv n_attn
	attn_tsv=$(printf '%s' "$attn_json" | jq -r 'map(select(.flags != "")) | sort_by(.rank) | .[] | "\(.rank)\t\(.flags)\t\(.short)\t\(.uuid)\t\(.project)\t\(.desc)\t\(.pid)\t\(.elapsed)\t\(.quiet)"' 2>/dev/null || true)
	n_attn=$(printf '%s' "$attn_tsv" | grep -c . || true)
	[[ "$n_attn" =~ ^[0-9]+$ ]] || n_attn=0
	if [ "$n_attn" -gt 0 ]; then
		section "NEEDS ATTENTION  (${n_attn})"
		local _ashown=0 _arank _aflags _ashort _auuid _aproj _adesc _apid _ael _aq
		while IFS=$'\t' read -r _arank _aflags _ashort _auuid _aproj _adesc _apid _ael _aq; do
			[ -n "$_ashort" ] || continue
			_ashown=$((_ashown + 1))
			if [ "$_ashown" -gt "$list_max" ]; then
				printf '  %s… +%d more (use --verbose)%s\n' "$DIM" "$((n_attn - list_max))" "$RESET"
				break
			fi
			case "$_aflags" in
			*orphan*)
				printf '  %s! orphan%s %s [%s] %s — owner pid %s gone (started %s ago; run: task %s stop)\n' \
					"$Y" "$RESET" "$_ashort" "$_aproj" "$(trunc_str "$_adesc" "$desc_max")" "$_apid" "$(dur "$_ael")" "$_ashort"
				;;
			*stuck*)
				printf '  %s! stuck%s %s [%s] %s — active + drain-failed, invisible to workers (run: task %s stop)\n' \
					"$Y" "$RESET" "$_ashort" "$_aproj" "$(trunc_str "$_adesc" "$desc_max")" "$_ashort"
				;;
			*unlinked*)
				printf '  %s! unlinked%s %s [%s] %s — drain-claimed but no claim note (run: task %s stop)\n' \
					"$Y" "$RESET" "$_ashort" "$_aproj" "$(trunc_str "$_adesc" "$desc_max")" "$_ashort"
				;;
			*stale*)
				printf '  %s! stale%s %s [%s] %s — active %s with no completion (auto-release window is 4h)\n' \
					"$Y" "$RESET" "$_ashort" "$_aproj" "$(trunc_str "$_adesc" "$desc_max")" "$(dur "$_ael")"
				;;
			*manual-idle*)
				printf '  %s! manual%s %s [%s] %s — started outside drain %s ago, quiet %s (drain never touches started tasks)\n' \
					"$Y" "$RESET" "$_ashort" "$_aproj" "$(trunc_str "$_adesc" "$desc_max")" "$(dur "$_ael")" "$(dur "$_aq")"
				;;
			esac
		done <<<"$attn_tsv"
	fi

	# ================= failed =================
	section "FAILED  (${n_failed} need review)"
	local failed_lines
	failed_lines=$(printf '%s' "$failed_json" | jq -r 'sort_by(.urgency // 0) | reverse | .[] | "\(.uuid // "?")\t\(.project // "-")\t\((.description // "?") | gsub("[\t\n]"; " "))"' 2>/dev/null || true)
	if [ -z "$failed_lines" ]; then
		echo "  none"
	else
		local _pshown=0 uuid pproj pdesc short
		while IFS=$'\t' read -r uuid pproj pdesc; do
			[ -n "$pdesc" ] || continue
			_pshown=$((_pshown + 1))
			if [ "$_pshown" -gt "$fail_max" ]; then
				printf '  %s… +%d more (use --verbose)%s\n' "$DIM" "$((n_failed - fail_max))" "$RESET"
				break
			fi
			short=${uuid:0:8}
			printf '  • [%s] %s  %s(%s)%s\n' "$pproj" "$(trunc_str "$pdesc" "$desc_max")" "$DIM" "$short" "$RESET"
		done <<<"$failed_lines"
		printf '  %sre-queue: task <uuid> modify -drain-failed%s\n' "$DIM" "$RESET"
	fi

	# ================= by project (verbose only) =================
	if [ "$verbose" = 1 ]; then
		local proj_lines proj_max
		proj_lines=$(printf '%s' "$eligible_json" | jq -r '
      group_by(.project // "(none)")
      | map({p: (.[0].project // "(none)"), n: length})
      | sort_by(-.n) | .[]
      | "\(.n)\t\(.p)"' 2>/dev/null || true)
		if [ -n "$proj_lines" ]; then
			proj_max=$(printf '%s\n' "$proj_lines" | head -n1 | cut -f1 || echo 1)
			[[ "$proj_max" =~ ^[0-9]+$ ]] || proj_max=1
			[ "$proj_max" -ge 1 ] || proj_max=1
			section "ELIGIBLE BY PROJECT  (${n_elig} eligible of ${n_pending_total} pending)"
			local shown=0 top_n=15 count proj b
			while IFS=$'\t' read -r count proj; do
				[ -n "$count" ] || continue
				shown=$((shown + 1))
				[ "$shown" -gt "$top_n" ] && break
				b=$(bar "$count" "$proj_max" 18)
				printf '  %s%4s%s  %-22.22s  %s%s%s\n' "$B" "$count" "$RESET" "$proj" "$DIM" "$b" "$RESET"
			done <<<"$proj_lines"
		fi
	fi

	divider
	printf '%scommands:%s drain status [project] [--workers] [--verbose] · drain start [N] [project] · drain stop · drain kill · drain resume · drain logs [-f]\n' "$DIM" "$RESET"
}

cmd_workers() {
	# One snapshot frame: live workers, the task each one owns right now,
	# and a time-budget meter per worker (elapsed vs TASK_TIMEOUT_SEC).
	# Rendered directly for pipes, or via cmd_watch for the live screen.
	# PROJECT_FILTER dims (not hides) other projects.
	[ -x "$TASK" ] || {
		echo "ERROR: $TASK not executable" >&2
		exit 1
	}
	command -v jq >/dev/null 2>&1 || {
		echo "ERROR: jq not found (brew install jq)" >&2
		exit 1
	}

	# --- terminal setup (same convention as cmd_status) ---
	local use_color=0
	if [ -n "${DRAIN_FORCE_COLOR:-}" ] && [ -z "${NO_COLOR:-}" ]; then
		use_color=1
	elif [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then use_color=1; fi
	local B="" C="" G="" Y="" R="" M="" DIM="" RESET=""
	if [ "$use_color" = 1 ]; then
		B=$'\033[1m'
		C=$'\033[36m'
		G=$'\033[32m'
		Y=$'\033[33m'
		R=$'\033[31m'
		M=$'\033[35m'
		DIM=$'\033[2m'
		RESET=$'\033[0m'
	fi
	local cols
	cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	[[ "$cols" =~ ^[0-9]+$ ]] || cols=80
	[ "$cols" -ge 40 ] || cols=40
	[ "$cols" -le 200 ] || cols=200

	divider() {
		local i
		for ((i = 0; i < cols; i++)); do printf '─'; done
		printf '\n'
	}
	trunc_str() { # $1=text $2=maxlen
		local s="$1" max="$2"
		if [ "${#s}" -gt "$max" ]; then printf '%s…' "${s:0:$((max - 1))}"; else printf '%s' "$s"; fi
	}
	fit() { # $1=text $2=fixed-overhead -> text truncated to fit $cols (min 10)
		local s="$1" max=$((cols - $2))
		[ "$max" -ge 10 ] || max=10
		trunc_str "$s" "$max"
	}
	meter() { # $1=elapsed_sec $2=budget_sec $3=width -> capped bar
		local el="$1" budget="$2" width="${3:-14}" fill empty i
		[[ "$el" =~ ^[0-9]+$ ]] || el=0
		[[ "$budget" =~ ^[0-9]+$ ]] || budget=1
		[ "$budget" -ge 1 ] || budget=1
		fill=$((el * width / budget))
		[ "$fill" -gt "$width" ] && fill=$width
		empty=$((width - fill))
		for ((i = 0; i < fill; i++)); do printf '█'; done
		for ((i = 0; i < empty; i++)); do printf '░'; done
	}
	fmt_dur() { # $1=sec -> 45s / 12m / 3h / 2d ; unknown -> ?
		local s="$1"
		[[ "$s" =~ ^[0-9]+$ ]] || {
			printf '?'
			return
		}
		if [ "$s" -lt 60 ]; then
			printf '%ss' "$s"
		elif [ "$s" -lt 7200 ]; then
			printf '%sm' "$((s / 60))"
		elif [ "$s" -lt 172800 ]; then
			printf '%sh' "$((s / 3600))"
		else printf '%sd' "$((s / 86400))"; fi
	}

	# --- sync (skipped on watch refreshes; first frame syncs) ---
	local sync_state="${DIM}sync: ok${RESET}"
	if [ -n "${DRAIN_NO_SYNC:-}" ]; then
		sync_state="${DIM}sync: live (no re-sync)${RESET}"
	elif ! $TASK sync >/dev/null 2>&1; then sync_state="${Y}sync: FAILED (showing local state)${RESET}"; fi

	# --- live workers, oldest first for stable rows ---
	local worker_ps live_pids _skip="$$" _p=$PPID _ppid _guard=0
	while [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -gt 1 ] && [ "$_guard" -lt 64 ]; do
		_skip="$_skip|$_p"
		_ppid=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || true)
		[[ "$_ppid" =~ ^[0-9]+$ ]] || break
		_p=$_ppid
		_guard=$((_guard + 1))
	done
	worker_ps=$(ps -eo pid,ppid,etime,command 2>/dev/null |
		awk -v skip="^($_skip)$" '/(^|[^A-Za-z0-9_-])[t]ask-drain\.sh/ && !/ status/ && !/ watch/ && !/ workers/ && $1 !~ skip { pid=$1; ppid=$2; pids[pid]=1; parent[pid]=ppid; et[pid]=$3; $1=$2=$3=""; sub(/^   */, ""); cmd[pid]=$0; next } END { for (p in pids) if (!(parent[p] in pids)) print p, et[p], cmd[p] }' | sort -n || true)
	live_pids=$(printf '%s\n' "$worker_ps" | awk 'NF {print $1}' | sort -n || true)

	# --- claimed tasks, global (project dimming happens at render) ---
	# Worker->task link: claim_task() annotates "claimed by drain-HOST-PID at …".
	local budget="${TASK_TIMEOUT_SEC:-7200}" stale_after="${STALE_AFTER_SEC:-14400}"
	[[ "$budget" =~ ^[0-9]+$ ]] || budget=7200
	[[ "$stale_after" =~ ^[0-9]+$ ]] || stale_after=14400
	local claims rows
	claims=$($TASK +drain-claimed +ACTIVE export 2>/dev/null || echo '[]')
	rows=$(printf '%s' "$claims" | jq -r '
    now as $now | .[] |
    {
      pid: ([.annotations // [] | .[].description | select(test("claimed by drain-|retrying previously failed"))]
            | last // "" | (capture("-(?<pid>[0-9]+)( at| retrying)") // null)
            | if . then .pid else "?" end),
      project: (.project // "-"),
      priority: (.priority // "-"),
      desc: ((.description // "?") | gsub("[\t\n]"; " ")),
      short: ((.uuid // "?") | .[0:8]),
      start: (.start // "?"),
      elapsed: (if .start then try (($now - (.start | strptime("%Y%m%dT%H%M%SZ") | mktime)) | floor) catch -1 else -1 end),
      notes: ((.annotations // []) | length),
      quiet: ([(.annotations // []) | .[].entry | select(. != null)
               | try (strptime("%Y%m%dT%H%M%SZ") | mktime) catch empty]
              | if length > 0 then (($now - max) | floor) else -1 end)
    }
    | "\(.pid)\t\(.project)\t\(.priority)\t\(.desc)\t\(.short)\t\(.start)\t\(.elapsed)\t\(.notes)\t\(.quiet)"' 2>/dev/null || true)

	local filter="${PROJECT_FILTER:-}"
	printf '%sDRAIN WORKERS%s  %s  ·  %s' "$B" "$RESET" "$(date '+%a %F %T %Z')" "$sync_state"
	if [ -n "$filter" ]; then printf '  ·  project: %s%s%s (others dimmed)' "$B" "$filter" "$RESET"; fi
	printf '\n'
	divider

	local nW=0 nWork=0 nIdle=0 nOrph=0
	if [ -z "$live_pids" ]; then
		printf '  %sno workers running%s — start with: drain start 2 [project]\n' "$DIM" "$RESET"
	else
		local pid etime row _r_pid r_proj r_pri r_desc r_short r_start r_el r_notes r_quiet
		while IFS= read -r pid; do
			[ -n "$pid" ] || continue
			nW=$((nW + 1))
			etime=$(awk -v p="$pid" '$1==p {print $2}' <<<"$worker_ps")
			row=$(awk -F'\t' -v p="$pid" '$1==p {print; exit}' <<<"$rows")
			if [ -z "$row" ]; then
				nIdle=$((nIdle + 1))
				printf '○ pid %-7s [%s]  %sidle — between tasks%s\n' "$pid" "${etime:-?}" "$DIM" "$RESET"
				continue
			fi
			nWork=$((nWork + 1))
			IFS=$'\t' read -r _r_pid r_proj r_pri r_desc r_short r_start r_el r_notes r_quiet <<<"$row"
			if [ -n "$filter" ] && [ "$r_proj" != "$filter" ]; then
				printf '%s○ pid %-7s [%s] · [%s] %s%s\n' "$DIM" "$pid" "${etime:-?}" \
					"$r_proj" "$(fit "$r_desc" $((32 + ${#r_proj})))" "$RESET"
				continue
			fi
			local wbar el_txt note_txt pri_c mark=""
			wbar=$(meter "$r_el" "$budget" 14)
			el_txt=$(fmt_dur "$r_el")
			if [ "$r_quiet" = "-1" ]; then note_txt="no notes yet"; else note_txt="note $(fmt_dur "$r_quiet") ago"; fi
			case "$r_pri" in
			H) pri_c="${R}H${RESET}" ;; M) pri_c="${Y}M${RESET}" ;; L) pri_c="${DIM}L${RESET}" ;; *) pri_c="${DIM}${r_pri}${RESET}" ;;
			esac
			if [[ "$r_el" =~ ^[0-9]+$ ]]; then
				[ "$r_el" -gt "$budget" ] && mark=" ${Y}OVER BUDGET${RESET}"
				[ "$r_el" -gt "$stale_after" ] && mark="$mark ${R}(stale)${RESET}"
			fi
			printf '%s●%s pid %-7s [%s]  [%s] %s/%s · %s · %s notes%s\n' \
				"$C" "$RESET" "$pid" "${etime:-?}" "$wbar" "$el_txt" "$(fmt_dur "$budget")" "$note_txt" "$r_notes" "$mark"
			local started_short="$r_start"
			if [[ "$r_start" =~ ^[0-9]{8}T([0-9]{2})([0-9]{2}) ]]; then started_short="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"; fi
			printf '  [%s] (%s) %s  %s(%s · %s)%s\n' \
				"$r_proj" "$pri_c" "$(fit "$r_desc" $((29 + ${#r_proj})))" "$DIM" "$r_short" "$started_short" "$RESET"
		done <<<"$live_pids"
	fi

	# --- orphaned claims: owner pid is not a live worker ---
	# Owner comes from the LAST claim-or-retry note, so retried tasks point
	# at their live worker instead of a dead pid (no more false orphans).
	# "?" owners never had a claim note: listed separately, not as orphans.
	local orphans="" unlinked="" o_line o_pid
	while IFS= read -r o_line; do
		[ -n "$o_line" ] || continue
		o_pid=$(cut -f1 <<<"$o_line")
		[ -n "$o_pid" ] || continue
		if [ "$o_pid" = "?" ]; then
			unlinked+="$o_line"$'\n'
		elif ! grep -qxF -- "$o_pid" <<<"$live_pids"; then orphans+="$o_line"$'\n'; fi
	done <<<"$rows"
	if [ -n "$orphans" ]; then
		printf '\n%sORPHANED CLAIMS (worker gone)%s\n' "$Y" "$RESET"
		local o_proj o_desc o_short o_start o_dim="" o_rst=""
		while IFS= read -r o_line; do
			[ -n "$o_line" ] || continue
			IFS=$'\t' read -r o_pid o_proj _opri o_desc o_short o_start _oel _on _oq <<<"$o_line"
			nOrph=$((nOrph + 1))
			o_dim=""
			o_rst=""
			if [ -n "$filter" ] && [ "$o_proj" != "$filter" ]; then
				o_dim="$DIM"
				o_rst="$RESET"
			fi
			printf '  %s• [%s] %s  %s(pid %s · %s · run: task %s stop)%s\n' \
				"$o_dim" "$o_proj" "$(fit "$o_desc" $((56 + ${#o_proj} + ${#o_pid})))" "$DIM" "$o_pid" "$o_start" "$o_short" "$o_rst"
		done <<<"$orphans"
	fi
	if [ -n "$unlinked" ]; then
		printf '\n%sCLAIMS WITHOUT OWNER NOTE%s\n' "$Y" "$RESET"
		while IFS= read -r o_line; do
			[ -n "$o_line" ] || continue
			IFS=$'\t' read -r o_pid o_proj _opri o_desc o_short o_start _oel _on _oq <<<"$o_line"
			o_dim=""
			o_rst=""
			if [ -n "$filter" ] && [ "$o_proj" != "$filter" ]; then
				o_dim="$DIM"
				o_rst="$RESET"
			fi
			printf '  %s• [%s] %s  %s(no claim annotation · %s · run: task %s stop)%s\n' \
				"$o_dim" "$o_proj" "$(fit "$o_desc" $((56 + ${#o_proj})))" "$DIM" "$o_start" "$o_short" "$o_rst"
		done <<<"$unlinked"
	fi

	divider
	printf '%s%d workers · %d working · %d idle · %d orphaned%s' "$DIM" "$nW" "$nWork" "$nIdle" "$nOrph" "$RESET"
	[ -n "$filter" ] && printf '  ·  filter: %s' "$filter"
	printf '\n'
}

# Watch-mode frame diffing: only rows whose content changed are rewritten,
# so static labels/headings are never touched (no flicker). 1-based rows.
_WATCH_PREV=()
_WATCH_RESIZE=0
_WATCH_STTY=""
restore_watch() {
	if [ -n "$_WATCH_STTY" ]; then stty $_WATCH_STTY 2>/dev/null || true; fi
	printf '\033[?25h\033[?1049l'
}
paint_frame() { # $1 = full frame text
	local line="" i=0 n_new=0 n_old=0
	local -a cur=()
	while IFS= read -r line; do cur+=("$line"); done <<<"$1"
	n_new=${#cur[@]}
	n_old=${#_WATCH_PREV[@]}
	for ((i = 0; i < n_new; i++)); do
		if [ "$i" -ge "$n_old" ] || [ "${cur[i]}" != "${_WATCH_PREV[i]}" ]; then
			printf '\033[%d;1H\033[2K%s' "$((i + 1))" "${cur[i]}"
		fi
	done
	for ((i = n_new; i < n_old; i++)); do
		printf '\033[%d;1H\033[2K' "$((i + 1))"
	done
	if [ "$n_new" -gt 0 ]; then _WATCH_PREV=("${cur[@]}"); else _WATCH_PREV=(); fi
}

cmd_watch() { # [renderer] -- live alternate-screen display, q quits
	# Live display: alternate screen + hidden cursor, differential redraw
	# (see paint_frame). First frame syncs; refreshes reuse local state
	# (re-sync on restart). q quits. Falls back to one plain dump when
	# stdout is not a TTY.
	local render="${1:-cmd_status}"
	local INTERVAL="${DRAIN_WATCH_INTERVAL:-5}" key="" frame=""
	[[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=5
	[ "$INTERVAL" -ge 2 ] || INTERVAL=2
	if [ ! -t 1 ]; then
		"$render"
		return
	fi
	COLUMNS=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	[[ "$COLUMNS" =~ ^[0-9]+$ ]] || COLUMNS=80
	export COLUMNS
	export DRAIN_FORCE_COLOR=1
	printf '\033[?1049h\033[?25l'
	_WATCH_STTY=""
	if [ -t 0 ]; then
		_WATCH_STTY=$(stty -g 2>/dev/null || true)
		[ -n "$_WATCH_STTY" ] && stty -echo 2>/dev/null || true
	fi
	trap restore_watch EXIT
	trap 'exit 130' INT TERM
	trap '_WATCH_RESIZE=1' WINCH
	_WATCH_PREV=()
	_WATCH_RESIZE=0
	frame="$("$render")"
	frame="$frame
[live every ${INTERVAL}s — q to quit]"
	[ -n "$frame" ] && paint_frame "$frame"
	DRAIN_NO_SYNC=1
	while true; do
		key=""
		if [ -t 0 ]; then
			IFS= read -r -t "$INTERVAL" -n 1 -s key 2>/dev/null || true
			[ "$key" = "q" ] && break
		else
			sleep "$INTERVAL"
		fi
		if [ "${_WATCH_RESIZE:-0}" = "1" ]; then
			printf '\033[H\033[J'
			_WATCH_PREV=()
			_WATCH_RESIZE=0
		fi
		frame="$("$render")"
		frame="$frame
[live every ${INTERVAL}s — q to quit]"
		[ -n "$frame" ] && paint_frame "$frame"
	done
	restore_watch
	trap - EXIT INT TERM WINCH
}

case "${1:-run}" in
run) run_worker ;;
status) cmd_status ;;
watch) cmd_watch ;;
workers) cmd_watch cmd_workers ;;
*)
	echo "usage: bash $0 [run|status|watch|workers]" >&2
	exit 2
	;;
esac
