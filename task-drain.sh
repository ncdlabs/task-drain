#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.opencode/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin

# Source shared display and worker detection functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/display.sh
source "$SCRIPT_DIR/lib/display.sh"
# shellcheck source=lib/worker-detect.sh
source "$SCRIPT_DIR/lib/worker-detect.sh"
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
# (Run directly -- both scripts carry the exec bit -- or with `bash script`.)
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
#                      task <uuid> modify -drain-failed
#
# RETRY MODE (DRAIN_RETRY_FAILED=1):
#   Workers reprocess drain-failed tasks instead of the regular queue.
#   The failed set is snapshotted at worker start; each task is retried at
#   most once per run, so a task that fails again can't loop -- it keeps
#   drain-failed for the next explicit retry. Launched via:
#     drain start [N] [project] --failed
#
# SAFETY DIALS:
#   DRAIN_SKIP_PERMISSIONS -- set to 1 to add --dangerously-skip-permissions
#     to opencode run flags. Without it, unattended runs stall on the first
#     approval prompt. With it, the agent can edit, run, and push without
#     asking. This is the main risk dial -- only enable it if you trust the
#     autonomous worker to operate without human approval.
#   OPENCODE_RUN_FLAGS -- default --standalone --model $DRAIN_MODEL
#     (default opencode-go/longcat-2.5-preview-free; override with the
#     DRAIN_MODEL env var). Verify flags with: opencode run --help
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
# matters (those belong to the project owner -- see DRAIN_OWNER below):
# it must annotate and fail instead.
#
set -euo pipefail

# Taskwarrior binary. Override with TASK=/path/to/task in the environment.
# Defaults to `task` on PATH, falling back to the Homebrew location on macOS.
TASK="${TASK:-$(command -v task 2>/dev/null || echo /opt/homebrew/bin/task)}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
# Model for worker runs. Override with DRAIN_MODEL in the environment.
DRAIN_MODEL="${DRAIN_MODEL:-opencode-go/longcat-2.5-preview-free}"
# --dangerously-skip-permissions is OPT-IN (set DRAIN_SKIP_PERMISSIONS=1).
# Without it, unattended runs stall on the first approval prompt.
OPENCODE_RUN_FLAGS=(--standalone --model "$DRAIN_MODEL")
if [ "${DRAIN_SKIP_PERMISSIONS:-0}" = "1" ]; then
	OPENCODE_RUN_FLAGS+=(--dangerously-skip-permissions)
fi
# Agent harness to use for worker runs: opencode | claude | codex.
# Override with DRAIN_AGENT in the environment.
DRAIN_AGENT="${DRAIN_AGENT:-opencode}"
# Name shown in the worker prompt as the human authority for design/security/
# product decisions (workers must not make these). Override with DRAIN_OWNER.
DRAIN_OWNER="${DRAIN_OWNER:-the project owner}"
STALE_AFTER_SEC="${STALE_AFTER_SEC:-14400}"   # 4 hours
TASK_TIMEOUT_SEC="${TASK_TIMEOUT_SEC:-14400}" # 4 hours per task (gtimeout only)
# Validate numeric environment variables
[[ "$STALE_AFTER_SEC" =~ ^[0-9]+$ ]] || STALE_AFTER_SEC=14400
[[ "$TASK_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || TASK_TIMEOUT_SEC=14400
# Default timeout used in cmd_workers display (kept in sync with above)
_DRAIN_DEFAULT_TIMEOUT=14400
PROJECT_FILTER="${PROJECT_FILTER:-}"
DRAIN_RETRY_FAILED="${DRAIN_RETRY_FAILED:-0}" # 1 = reprocess drain-failed tasks instead of the regular queue
RETRY_SNAPSHOT=""                             # temp file holding retry UUIDs for this run
GIT_ROOT="${GIT_ROOT:-$HOME/git}"
STOP_FILE="$HOME/.task-drain/STOP"
WORKER_ID="drain-$(hostname -s)-$$"
CHILD_PID=""
CURRENT_UUID=""

log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$WORKER_ID" "$*" >&2; }

# Debug logging: set DRAIN_DEBUG=1 for verbose output
debug() { [ "${DRAIN_DEBUG:-0}" = "1" ] && printf '[%s] [%s] DEBUG: %s\n' "$(date '+%F %T')" "$WORKER_ID" "$*" >&2 || true; }

# Error reporting: send critical failures to a webhook (Slack, Discord, etc.)
# Set DRAIN_ERROR_WEBHOOK to enable. Errors are also always logged locally.
report_error() { # $1 = error message
	local webhook="${DRAIN_ERROR_WEBHOOK:-}"
	[ -n "$webhook" ] || return 0
	local payload
	payload=$(jq -nc --arg worker "$WORKER_ID" --arg msg "$1" --arg host "$(hostname -s)" \
		'{text: "🚨 task-drain error on \($host) [\($worker)]: \($msg)"}')
	curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$webhook" >/dev/null 2>&1 || true
}

stop_requested() { [ -e "$STOP_FILE" ] || [ -e "${STOP_FILE}.$$" ]; }

stop_scope() { # why this worker is stopping: global|personal|none
	if [ -e "$STOP_FILE" ]; then
		echo global
	elif [ -e "${STOP_FILE}.$$" ]; then
		echo personal
	else echo none; fi
}

claim_task() { # $1 = uuid
	if ! $TASK "$1" modify +drain-claimed >/dev/null 2>&1; then
		report_error "claim_task: failed to add drain-claimed tag to $1"
		return 1
	fi
	if [ "$DRAIN_RETRY_FAILED" = "1" ]; then
		$TASK "$1" modify -drain-failed >/dev/null 2>&1 || true
		$TASK "$1" annotate "drain worker $WORKER_ID retrying previously failed attempt ($(date -u +%Y-%m-%dT%H:%M:%SZ))" >/dev/null 2>&1 || true
	else
		$TASK "$1" annotate "claimed by $WORKER_ID at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true
	fi
	if ! $TASK "$1" start >/dev/null 2>&1; then
		report_error "claim_task: failed to start task $1"
		return 1
	fi
	$TASK sync >/dev/null 2>&1 || report_error "claim_task: sync failed after claiming $1"
}

release_claim() { # $1 = uuid, $2 = reason annotation
	$TASK "$1" modify -drain-claimed >/dev/null 2>&1 || report_error "release_claim: failed to remove drain-claimed from $1"
	$TASK "$1" annotate "$2" >/dev/null 2>&1 || true
	$TASK "$1" stop >/dev/null 2>&1 || true
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

# Project → repo mapping:
# 1. repos.conf (~/.task-drain/repos.conf) is PRIMARY — one per line:
#      myproject=$HOME/git/myrepo   (or ~/git/myrepo)
# 2. Auto-detect: scan $GIT_ROOT for a directory matching the project name
# 3. Built-in table below is the fallback (for backwards compatibility)
repo_for_project() {
	local conf="$HOME/.task-drain/repos.conf" proj path
	# 1. repos.conf (primary)
	if [ -f "$conf" ]; then
		while IFS='=' read -r proj path; do
			case "$proj" in '' | \#*) continue ;; esac
			if [ "$proj" = "${1:-}" ]; then
				path="${path/#\~/$HOME}"
				path="${path//\$HOME/$HOME}"
				echo "$path"
				return 0
			fi
		done <"$conf"
	fi
	# 2. Auto-detect: look for a directory matching the project name
	if [ -d "$GIT_ROOT/${1:-}" ]; then
		echo "$GIT_ROOT/${1:-}"
		return 0
	fi
	# 3. Built-in fallback table
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
	local export_output
	export_output=$($TASK $filter export 2>/dev/null)
	if [ -z "$export_output" ]; then
		report_error "pick_task: task export returned empty (binary missing or sync error?)"
		echo ""
		return
	fi
	echo "$export_output" | jq -c 'sort_by(.urgency // 0) | reverse | .[0] // empty'
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
	local stale_uuids
	stale_uuids=$($TASK +drain-claimed +ACTIVE export 2>/dev/null |
		jq -r --argjson cutoff "$cutoff" \
			'.[] | select(.start and ((.start | strptime("%Y%m%dT%H%M%SZ") | mktime) < $cutoff)) | .uuid' 2>/dev/null)
	if [ -z "$stale_uuids" ]; then
		debug "reclaim_stale: no stale claims found"
		return
	fi
	echo "$stale_uuids" | while IFS= read -r uuid; do
		[ -n "$uuid" ] || continue
		log "releasing stale claim: $uuid"
		release_claim "$uuid" "drain worker: released stale claim (active > $((STALE_AFTER_SEC / 3600))h, no completion)"
	done
	$TASK sync >/dev/null 2>&1 || report_error "reclaim_stale: sync failed after releasing stale claims"
}

build_prompt() { # $1 uuid $2 project $3 priority $4 description $5 annotations $6 repo
	cat <<PROMPT_EOF
You are an autonomous coding-agent worker. Work exactly ONE Taskwarrior task to completion, then stop. Do not pick up other tasks.

TASK
  UUID:        $1   <- always reference tasks by UUID, never short numeric IDs
  Project:     $2
  Priority:    $3
  Description: $4
  Annotations:
$5

ENVIRONMENT
- Repos live under $GIT_ROOT. Your working directory is: $6
- Taskwarrior binary: $TASK (use this exact full path; it talks to the shared TaskChampion pool)
- 'git pull --rebase' before starting. Never force-push. Never change the task sync client ID.

DISCIPLINE (non-negotiable)
- Taskwarrior is the only system of record. Run '$TASK sync' at session start, after every change, and at session end.
- If sync fails: stop, annotate the failure on the task, report it, do not continue offline.
- Keep annotations current as you work. Search for duplicates before creating any task.
- Durable decisions go in the repo's docs/DECISIONS.md, not in tasks.

AUTHORITY (non-negotiable)
- Design, security, product, and public-facing decisions belong to $DRAIN_OWNER. You do not make them.
- If this task needs human judgment, credentials you do not have, a legal/compliance declaration, publishing or submitting anything public, or any irreversible action beyond the task's stated scope: DO NOT complete it. Annotate exactly what is needed and by whom, run '$TASK $1 stop', sync, and print FAILED: <reason> as your final line.

COMPLETION CONTRACT
- Do the work. Verify it for real: run the build, the tests, or the task's own acceptance criteria. Never assert success you did not observe.
- Only when the acceptance criteria are truly met: annotate a short summary of what changed, run '$TASK $1 done', sync, and print DONE: <one-line summary> as your final line.
- If you cannot meet the criteria: annotate the precise blocker, run '$TASK $1 stop' (leave it pending), sync, and print FAILED: <reason>. Never mark done on partial or unverified work.

GIT WORKFLOW (when the task involves code changes)
- Work on a feature branch, never directly on main/master. If not already on a branch, create one: git checkout -b <task-desc-short>
- Commit your changes with a clear message referencing the task UUID.
- Push the branch: git push -u origin <branch-name>
- Create a PR and leave it open for review. Never merge it yourself.
  - For GitHub repos: gh pr create --title "<task description>" --body "Task <uuid>. <summary>"
  - For Gitea / self-hosted forges: use the forge's API, e.g.:
    curl -s -X POST -H "Authorization: token \$FORGE_TOKEN" -H "Content-Type: application/json" \
      -d '{"title":"<task description>","head":"<branch>","base":"main","body":"Task <uuid>. <summary>"}' \
      https://<your-forge-host>/api/v1/repos/<owner>/<repo>/pulls
    (Export FORGE_TOKEN in your shell environment -- e.g. ~/.zshenv or ~/.bashrc --
    so non-interactive shells can see it.)
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
	# NOTE: `opencode run` has no --dir flag (verify with: opencode run --help),
	# so the working directory is set via subshell cd. Runs use --standalone
	# (avoids hangs when stdin is not a TTY) with stdin redirected from
	# /dev/null. A bad flag here fails every task and mass-fails the queue
	# as +drain-failed without doing any work.
	# Launch the agent harness. Each harness has its own non-interactive CLI.
	case "$DRAIN_AGENT" in
	opencode)
		if command -v gtimeout >/dev/null 2>&1; then
			(cd "$repo" && exec gtimeout "$TASK_TIMEOUT_SEC" "$OPENCODE_BIN" run "${OPENCODE_RUN_FLAGS[@]}" "$prompt" </dev/null) &
		else
			(cd "$repo" && exec "$OPENCODE_BIN" run "${OPENCODE_RUN_FLAGS[@]}" "$prompt" </dev/null) &
		fi
		;;
	claude)
		# Claude Code headless: claude -p prints the final response and exits.
		if command -v gtimeout >/dev/null 2>&1; then
			(cd "$repo" && exec gtimeout "$TASK_TIMEOUT_SEC" claude -p "$prompt" </dev/null) &
		else
			(cd "$repo" && exec claude -p "$prompt" </dev/null) &
		fi
		;;
	codex)
		# Codex CLI non-interactive: codex exec runs the prompt and exits.
		if command -v gtimeout >/dev/null 2>&1; then
			(cd "$repo" && exec gtimeout "$TASK_TIMEOUT_SEC" codex exec "$prompt" </dev/null) &
		else
			(cd "$repo" && exec codex exec "$prompt" </dev/null) &
		fi
		;;
	*)
		log "ERROR: unknown DRAIN_AGENT='$DRAIN_AGENT' (expected opencode|claude|codex)"
		return 1
		;;
	esac
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
	if ! $TASK "$uuid" modify +drain-failed >/dev/null 2>&1; then
		report_error "run_one: failed to tag $uuid as drain-failed (task may be re-picked)"
	fi
	release_claim "$uuid" "drain worker $WORKER_ID: agent exited (rc=$rc) without completing; tagged drain-failed, not auto-retried"
	$TASK sync >/dev/null 2>&1 || report_error "run_one: sync failed after marking $uuid as drain-failed"
	return 1
}

run_worker() {
	case "$DRAIN_AGENT" in
	opencode) _agent_bin="$OPENCODE_BIN" ;;
	claude) _agent_bin="claude" ;;
	codex) _agent_bin="codex" ;;
	esac
	command -v "$_agent_bin" >/dev/null 2>&1 || {
		log "ERROR: '$_agent_bin' (DRAIN_AGENT=$DRAIN_AGENT) not found on PATH"
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

	# --- terminal setup: shared display functions ---
	drain_terminal_setup
	local B="$DRAIN_B" C="$DRAIN_C" G="$DRAIN_G" Y="$DRAIN_Y" R="$DRAIN_R" M="$DRAIN_M" DIM="$DRAIN_DIM" RESET="$DRAIN_RESET"
	local cols="$DRAIN_COLS"
	alias divider=drain_divider
	alias section=drain_section
	alias trunc_str=drain_trunc_str
	alias bar=drain_bar

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

	# --- workers (shared detection logic) ---
	local worker_ps nworkers
	worker_ps=$(drain_worker_info)
	if [ -z "$worker_ps" ]; then nworkers=0; else nworkers=$(printf '%s\n' "$worker_ps" | wc -l | tr -d ' '); fi
	[[ "$nworkers" =~ ^[0-9]+$ ]] || nworkers=0

	# --- kill switch / autoscale state ---
	local ks_dot
	if stop_requested; then
		ks_dot="${R}■ STOPPED${RESET}"
	elif [ -f "$HOME/.task-drain/autoscale.pid" ] && kill -0 "$(cat "$HOME/.task-drain/autoscale.pid" 2>/dev/null)" 2>/dev/null; then
		ks_dot="${C}◈ AUTOSCALE${RESET}"
	else
		ks_dot="${G}● LIVE${RESET}"
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
	local n_claimed_active n_interactive n_stale n_pending_total
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

	# --- terminal setup (shared display functions) ---
	drain_terminal_setup
	local B="$DRAIN_B" C="$DRAIN_C" G="$DRAIN_G" Y="$DRAIN_Y" R="$DRAIN_R" M="$DRAIN_M" DIM="$DRAIN_DIM" RESET="$DRAIN_RESET"
	local cols="$DRAIN_COLS"
	alias divider=drain_divider
	alias trunc_str=drain_trunc_str
	alias meter=drain_meter
	alias fmt_dur=drain_fmt_dur
	fit() { # $1=text $2=fixed-overhead -> text truncated to fit $cols (min 10)
		local s="$1" max=$((cols - $2))
		[ "$max" -ge 10 ] || max=10
		trunc_str "$s" "$max"
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
	local budget="${TASK_TIMEOUT_SEC:-$_DRAIN_DEFAULT_TIMEOUT}" stale_after="${STALE_AFTER_SEC:-14400}"
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

# Autoscale supervisor: watches queue depth, scales workers to match.
# Runs as a daemon via `drain autoscale`. Stops on SIGTERM or STOP file.
autoscale_supervisor() {
	local min_w="${DRAIN_MIN_WORKERS:-1}"
	local max_w="${DRAIN_MAX_WORKERS:-8}"
	local interval="${DRAIN_AUTOSCALE_INTERVAL:-30}"
	local tasks_per_worker="${DRAIN_TASKS_PER_WORKER:-2}"
	log "autoscaler starting (min=$min_w max=$max_w interval=${interval}s)"

	trap 'log "autoscaler stopping"; exit 0' TERM INT

	while true; do
		# Stop if kill switch tripped
		if [ -e "$STOP_FILE" ]; then
			log "autoscaler: STOP file present, exiting"
			exit 0
		fi

		# Sync and count eligible tasks
		$TASK sync >/dev/null 2>&1 || log "autoscaler: sync failed, using local state"
		local eligible
		eligible=$(tq +PENDING -ACTIVE -WAITING -BLOCKED -noauto -drain-failed count 2>/dev/null || echo "0")
		[[ "$eligible" =~ ^[0-9]+$ ]] || eligible=0

		# Count running workers
		local running
		running=$(pgrep -f "bash $DRAIN_SCRIPT$" 2>/dev/null | wc -l | tr -d ' ')
		[[ "$running" =~ ^[0-9]+$ ]] || running=0
		# Exclude ourselves from the count
		running=$((running > 0 ? running - 1 : 0))

		# Desired workers: enough to cover eligible tasks, clamped to [min, max]
		local desired=$(((eligible + tasks_per_worker - 1) / tasks_per_worker))
		[ "$desired" -lt "$min_w" ] && desired="$min_w"
		[ "$desired" -gt "$max_w" ] && desired="$max_w"
		# If nothing eligible and min is 0, scale to zero
		if [ "$eligible" -eq 0 ] && [ "$min_w" -eq 0 ]; then desired=0; fi

		if [ "$desired" -gt "$running" ]; then
			local to_start=$((desired - running))
			log "autoscaler: eligible=$eligible running=$running -> starting $to_start worker(s)"
			for _i in $(seq 1 "$to_start"); do
				local logf="$LOG_DIR/worker-$(date '+%Y%m%d-%H%M%S')-autoscale-$_.log"
				nohup bash "$DRAIN_SCRIPT" >>"$logf" 2>&1 &
			done
		elif [ "$desired" -lt "$running" ]; then
			local to_stop=$((running - desired))
			log "autoscaler: eligible=$eligible running=$running -> stopping $to_stop worker(s) gracefully"
			# Signal excess workers via per-worker STOP files (they finish current task)
			local pids
			pids=$(pgrep -f "bash $DRAIN_SCRIPT$" 2>/dev/null | grep -v "^$$$" | head -"$to_stop")
			for pid in $pids; do
				touch "$HOME/.task-drain/STOP.$pid" 2>/dev/null
			done
		fi

		sleep "$interval"
	done
}

case "${1:-run}" in
run) run_worker ;;
autoscale) autoscale_supervisor ;;
status) cmd_status ;;
watch) cmd_watch ;;
workers) cmd_watch cmd_workers ;;
*)
	echo "usage: bash $0 [run|status|watch|workers|autoscale]" >&2
	exit 2
	;;
esac
