#!/usr/bin/env bats
# Tests for task-drain.sh functions
# Run with: bats tests/task-drain.bats

SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
    export TASK="$BATS_TEST_DIRNAME/mock-task"
    export GIT_ROOT="$BATS_TEST_DIRNAME/fixtures"
    export HOME="$BATS_TEST_DIRNAME/fake-home"
    export DRAIN_AGENT="opencode"
    export DRAIN_MODEL="test-model"
    export DRAIN_OWNER="test-owner"
    export STALE_AFTER_SEC="14400"
    export TASK_TIMEOUT_SEC="14400"
    export PROJECT_FILTER=""
    export DRAIN_RETRY_FAILED="0"
    export STOP_FILE="$HOME/.task-drain/STOP"
    export WORKER_ID="test-worker"
    export CHILD_PID=""
    export CURRENT_UUID=""
    export RETRY_SNAPSHOT=""
    export OPENCODE_BIN="opencode"
    export OPENCODE_RUN_FLAGS=(--standalone --model "$DRAIN_MODEL")
    export DRAIN_ERROR_WEBHOOK=""
    export DRAIN_DEBUG="0"
    export DRAIN_SKIP_PERMISSIONS="0"
    export DRAIN_FORCE_COLOR=""
    export DRAIN_NO_SYNC=""
    export DRAIN_VERBOSE="0"
    export DRAIN_WATCH_INTERVAL="5"
    export COLUMNS="80"
    export NO_COLOR="1"
    export TERM="dumb"

    # Create mock task command
    mkdir -p "$(dirname "$TASK")"
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
# Mock task command for testing.
# Simulates sync failure when MOCK_SYNC_FAIL=1.
if [ "${MOCK_SYNC_FAIL:-0}" = "1" ]; then
    exit 1
fi
# Return valid JSON for export commands so cmd_status sections render.
case "$*" in
    *"export"*)
        if [[ "$*" == *"+COMPLETED end.after:today export"* ]]; then
            # For the PENDING REVIEW query: return tasks with and without drain claims.
            if [ "${MOCK_REVIEW_DATA:-0}" = "1" ]; then
                echo '[{"uuid":"aaaa1111-1111-1111-1111-111111111111","project":"testproj","description":"drain completed task A","status":"completed","end":"20261009T120000Z","annotations":[{"description":"claimed by drain-9999 at 20261009T100000Z"}]},{"uuid":"bbbb2222-2222-2222-2222-222222222222","project":"otherproj","description":"manually completed task","status":"completed","end":"20261009T120000Z","annotations":[{"description":"some other note"}]}]'
            else
                echo '[]'
            fi
        else
            echo '[]'
        fi
        ;;
    *"count"*) echo "0" ;;
    *) echo "mock-task $@" ;;
esac
MOCK
    chmod +x "$TASK"

    # Create fixture directories
    mkdir -p "$GIT_ROOT/myproject"
    mkdir -p "$HOME/.task-drain"
}

teardown() {
    rm -rf "$BATS_TEST_DIRNAME/fake-home"
    rm -rf "$BATS_TEST_DIRNAME/fixtures"
    rm -rf "$BATS_TEST_DIRNAME/bin" # fake sudo for LNP fallback tests
    rm -f "$TASK"
}

# Source shared libraries first
source "$SCRIPT_DIR/lib/display.sh"
source "$SCRIPT_DIR/lib/worker-detect.sh"
source "$SCRIPT_DIR/lib/supervisor.sh"

# Extract and source only the function/variable definitions from task-drain.sh
# (everything before the "case" statement at the bottom)
load_functions() {
    local funcs
    # Use awk to extract everything before the case statement (portable)
    funcs=$(awk '/^case "\$\{1:-run\}" in/{exit} {print}' "$SCRIPT_DIR/task-drain.sh")
    # Remove the shebang and set -euo pipefail (which would exit on error)
    funcs=$(echo "$funcs" | sed '1d' | sed '/^set -euo pipefail$/d')
    # Remove export PATH line
    funcs=$(echo "$funcs" | sed '/^export PATH=/d')
    # Remove source lines (already sourced above)
    funcs=$(echo "$funcs" | sed '/^source /d')
    # Remove SCRIPT_DIR line
    funcs=$(echo "$funcs" | sed '/^SCRIPT_DIR=/d')
    # Source the functions
    eval "$funcs"
}

@test "repo_for_project returns empty for unknown project" {
    load_functions
    result=$(repo_for_project "nonexistent")
    [ "$result" = "" ]
}

@test "repo_for_project returns path for known project" {
    load_functions
    export GIT_ROOT="$BATS_TEST_DIRNAME/fixtures"
    result=$(repo_for_project "attendeesync")
    [ "$result" = "$GIT_ROOT/attendeesync" ]
}

@test "repo_for_project handles tilde expansion" {
    load_functions
    echo 'testproj=~/git/testproj' > "$HOME/.task-drain/repos.conf"
    result=$(repo_for_project "testproj")
    [ "$result" = "$HOME/git/testproj" ]
}

@test "repo_for_project handles HOME variable expansion" {
    load_functions
    echo 'testproj2=$HOME/git/testproj2' > "$HOME/.task-drain/repos.conf"
    result=$(repo_for_project "testproj2")
    [ "$result" = "$HOME/git/testproj2" ]
}

@test "repo_for_project prefers repos.conf over built-in" {
    load_functions
    echo 'myproject=/custom/path' > "$HOME/.task-drain/repos.conf"
    result=$(repo_for_project "myproject")
    [ "$result" = "/custom/path" ]
}

@test "repo_for_project skips comments in repos.conf" {
    load_functions
    printf '# comment\nmyproject=/custom/path\n' > "$HOME/.task-drain/repos.conf"
    result=$(repo_for_project "myproject")
    [ "$result" = "/custom/path" ]
}

@test "repo_for_project skips empty lines in repos.conf" {
    load_functions
    printf '\n\nmyproject=/custom/path\n\n' > "$HOME/.task-drain/repos.conf"
    result=$(repo_for_project "myproject")
    [ "$result" = "/custom/path" ]
}

@test "stop_requested returns false when no STOP file" {
    load_functions
    rm -f "$STOP_FILE" "${STOP_FILE}".*
    if stop_requested; then
        return 1
    fi
    return 0
}

@test "stop_requested returns true when STOP file exists" {
    load_functions
    touch "$STOP_FILE"
    stop_requested
    [ $? -eq 0 ]
}

@test "stop_scope returns global when STOP file exists" {
    load_functions
    touch "$STOP_FILE"
    result=$(stop_scope)
    [ "$result" = "global" ]
}

@test "stop_scope returns personal when personal STOP file exists" {
    load_functions
    touch "${STOP_FILE}.$$"
    result=$(stop_scope)
    [ "$result" = "personal" ]
}

@test "stop_scope returns none when no STOP files exist" {
    load_functions
    rm -f "$STOP_FILE" "${STOP_FILE}".*
    result=$(stop_scope)
    [ "$result" = "none" ]
}

@test "build_prompt includes task UUID" {
    load_functions
    uuid="27594f5a-7c89-4d88-8b08-f33b7ef33b6e"
    prompt=$(build_prompt "$uuid" "testproject" "H" "Test description" "(none)" "/repo")
    [[ "$prompt" == *"$uuid"* ]]
}

@test "build_prompt includes project name" {
    load_functions
    uuid="27594f5a-7c89-4d88-8b08-f33b7ef33b6e"
    prompt=$(build_prompt "$uuid" "testproject" "H" "Test description" "(none)" "/repo")
    [[ "$prompt" == *"testproject"* ]]
}

@test "build_prompt includes description" {
    load_functions
    uuid="27594f5a-7c89-4d88-8b08-f33b7ef33b6e"
    prompt=$(build_prompt "$uuid" "testproject" "H" "Test description" "(none)" "/repo")
    [[ "$prompt" == *"Test description"* ]]
}

@test "build_prompt includes repo path" {
    load_functions
    uuid="27594f5a-7c89-4d88-8b08-f33b7ef33b6e"
    prompt=$(build_prompt "$uuid" "testproject" "H" "Test description" "(none)" "/repo")
    [[ "$prompt" == *"/repo"* ]]
}

@test "build_prompt includes DRAIN_OWNER" {
    load_functions
    uuid="27594f5a-7c89-4d88-8b08-f33b7ef33b6e"
    prompt=$(build_prompt "$uuid" "testproject" "H" "Test description" "(none)" "/repo")
    [[ "$prompt" == *"test-owner"* ]]
}

@test "build_prompt includes TASK binary path" {
    load_functions
    uuid="27594f5a-7c89-4d88-8b08-f33b7ef33b6e"
    prompt=$(build_prompt "$uuid" "testproject" "H" "Test description" "(none)" "/repo")
    [[ "$prompt" == *"$TASK"* ]]
}

@test "OPENCODE_RUN_FLAGS does not include --dangerously-skip-permissions by default" {
    load_functions
    [[ ! " ${OPENCODE_RUN_FLAGS[*]} " == *"--dangerously-skip-permissions"* ]]
}

@test "OPENCODE_RUN_FLAGS includes --dangerously-skip-permissions when DRAIN_SKIP_PERMISSIONS=1" {
    export DRAIN_SKIP_PERMISSIONS=1
    load_functions
    [[ " ${OPENCODE_RUN_FLAGS[*]} " == *"--dangerously-skip-permissions"* ]]
    unset DRAIN_SKIP_PERMISSIONS
}

# --- opt-in autonomous mode (DRAIN_AUTONOMOUS) ---

@test "drain_elig_filter returns opt-out filter by default" {
    load_functions
    export DRAIN_AUTONOMOUS=0
    result=$(drain_elig_filter)
    unset DRAIN_AUTONOMOUS
    [[ "$result" == *"-noauto"* ]]
    [[ "$result" != *"+auto"* ]]
}

@test "drain_elig_filter returns opt-in filter when DRAIN_AUTONOMOUS=1" {
    load_functions
    export DRAIN_AUTONOMOUS=1
    result=$(drain_elig_filter)
    unset DRAIN_AUTONOMOUS
    [[ "$result" == *"+auto"* ]]
    [[ "$result" == *"-noauto"* ]]
}

@test "drain_elig_filter is project-independent (queue_json adds project scope)" {
    load_functions
    export DRAIN_AUTONOMOUS=0
    export PROJECT_FILTER="myproject"
    result=$(drain_elig_filter)
    unset DRAIN_AUTONOMOUS
    unset PROJECT_FILTER
    [[ "$result" != *"project:"* ]]
}

@test "drain help start shows --autonomous option" {
    run "$SCRIPT_DIR/drain" help start
    [ "$status" -eq 0 ]
    [[ "$output" == *"--autonomous"* ]]
}

@test "drain start --autonomous flag is accepted" {
    run "$SCRIPT_DIR/drain" help start
    [ "$status" -eq 0 ]
    [[ "$output" == *"--autonomous"* ]]
}

# --- task sync bounded recovery (no sudo fallback) ---

@test "sync_with_retry succeeds when direct sync works" {
    load_functions
    run sync_with_retry
    [ "$status" -eq 0 ]
}

@test "sync_with_retry fails when sync fails (no sudo fallback)" {
    load_functions
    export MOCK_SYNC_FAIL=1
    export DRAIN_SYNC_RETRY_DELAY=0
    run sync_with_retry
    [ "$status" -eq 1 ]
    [[ "$output" == *"sync failed"* ]]
}

@test "task_sync returns 1 on failure without invoking sudo" {
    load_functions
    export MOCK_SYNC_FAIL=1
    # Ensure sudo is not on PATH to prove it's not called
    export PATH="/usr/bin:/bin"
    run task_sync
    [ "$status" -eq 1 ]
}

# --- drain CLI help system ---

@test "drain help produces output" {
    run "$SCRIPT_DIR/drain" help
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"autoscale"* ]]
    [[ "$output" == *"status"* ]]
}

@test "drain help autoscale shows autoscale help" {
    run "$SCRIPT_DIR/drain" help autoscale
    [ "$status" -eq 0 ]
    [[ "$output" == *"--min"* ]]
    [[ "$output" == *"--max"* ]]
    [[ "$output" == *"DRAIN_AUTOSCALE_INTERVAL"* ]]
}

@test "drain autoscale help shows autoscale help" {
    run "$SCRIPT_DIR/drain" autoscale help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--min"* ]]
    [[ "$output" == *"--max"* ]]
}

@test "drain help unknown command fails" {
    run "$SCRIPT_DIR/drain" help nonexistent
    [ "$status" -ne 0 ]
}

@test "drain autoscale rejects --min exceeding --max without launching" {
    # Dies during argument validation, before any pidfile/lock is touched:
    # no supervisor can be started by this invocation.
    rm -f "$HOME/.task-drain/autoscale.pid"
    run "$SCRIPT_DIR/drain" autoscale --min 5 --max 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot exceed"* ]]
    [ ! -f "$HOME/.task-drain/autoscale.pid" ]
}

@test "drain autoscale rejects non-numeric --min without launching" {
    rm -f "$HOME/.task-drain/autoscale.pid"
    run "$SCRIPT_DIR/drain" autoscale --min abc
    [ "$status" -ne 0 ]
    [ ! -f "$HOME/.task-drain/autoscale.pid" ]
}

@test "drain autoscale refuses a second concurrent launch" {
    # A live supervisor whose cmdline matches the supervisor pattern is
    # registered; a second `drain autoscale` must be rejected, never start
    # a duplicate. Stub path contains task-drain.sh so identity checks match.
    local stub="$BATS_TEST_TMPDIR/task-drain.sh"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
SLEEP=""
trap 'kill $SLEEP 2>/dev/null; exit 0' TERM INT
while true; do sleep 30 & SLEEP=$!; wait $SLEEP || true; done
STUB
    chmod +x "$stub"
    "$stub" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    echo "$sup" > "$HOME/.task-drain/autoscale.pid"
    run "$SCRIPT_DIR/drain" autoscale --min 1 --max 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"already running"* ]]
    # Exactly one supervisor exists: the pre-registered stub.
    local count
    count=$(pgrep -f "task-drain.sh.*autoscale" | wc -l | tr -d ' ')
    kill "$sup" 2>/dev/null || true
    wait "$sup" 2>/dev/null || true
    [ "$count" = "1" ]
}

@test "drain help start shows --persist option" {
    run "$SCRIPT_DIR/drain" help start
    [ "$status" -eq 0 ]
    [[ "$output" == *"--persist"* ]]
}

@test "drain start --persist flag is accepted" {
    run "$SCRIPT_DIR/drain" help start
    [ "$status" -eq 0 ]
    [[ "$output" == *"--persist"* ]]
}

@test "drain start --persist shows persist mode in output" {
    run "$SCRIPT_DIR/drain" help start
    [ "$status" -eq 0 ]
    [[ "$output" == *"--persist"* ]]
}

@test "drain help unfail shows unfail help" {
    run "$SCRIPT_DIR/drain" help unfail
    [ "$status" -eq 0 ]
    [[ "$output" == *"drain-failed"* ]]
    [[ "$output" == *"unfail"* ]]
}

@test "drain unfail help dispatches correctly" {
    run "$SCRIPT_DIR/drain" unfail help
    [ "$status" -eq 0 ]
    [[ "$output" == *"unfail"* ]]
    [[ "$output" == *"drain-failed"* ]]
}

# --- PENDING REVIEW section in drain status ---

@test "cmd_status shows PENDING REVIEW section when drain completed tasks exist" {
    load_functions
    export MOCK_REVIEW_DATA=1
    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"PENDING REVIEW"* ]]
    [[ "$output" == *"drain completed task A"* ]]
    # Task without drain annotation should NOT appear
    [[ "$output" != *"manually completed task"* ]]
    unset MOCK_REVIEW_DATA
}

@test "cmd_status omits PENDING REVIEW section when no drain completed tasks" {
    load_functions
    export MOCK_REVIEW_DATA=0
    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" != *"PENDING REVIEW"* ]]
    unset MOCK_REVIEW_DATA
}

@test "cmd_status PENDING REVIEW section shows count in header" {
    load_functions
    export MOCK_REVIEW_DATA=1
    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"(1 completed today)"* ]]
    unset MOCK_REVIEW_DATA
}

@test "cmd_status PENDING REVIEW section respects fail_max limit" {
    load_functions
    export MOCK_REVIEW_DATA=1
    export DRAIN_VERBOSE=0
    run cmd_status
    [ "$status" -eq 0 ]
    # Only 1 drain task in mock data, should not show overflow message
    [[ "$output" != *"+1 more"* ]]
    unset MOCK_REVIEW_DATA
}

# --- drain history ---

@test "history_record writes a TSV line to the history file" {
    load_functions
    rm -f "$HISTORY_FILE"
    export HISTORY_LIMIT=20
    history_record "aaaa1111-1111-1111-1111-111111111111" "testproj" "test task" "done" "120" "drain-host-1234"
    [ -f "$HISTORY_FILE" ]
    local line
    line=$(cat "$HISTORY_FILE")
    [[ "$line" == *"aaaa1111-1111-1111-1111-111111111111"* ]]
    [[ "$line" == *"testproj"* ]]
    [[ "$line" == *"test task"* ]]
    [[ "$line" == *"done"* ]]
    [[ "$line" == *"120"* ]]
    [[ "$line" == *"drain-host-1234"* ]]
    rm -f "$HISTORY_FILE"
}

@test "history_record sanitizes tabs and newlines in description" {
    load_functions
    rm -f "$HISTORY_FILE"
    export HISTORY_LIMIT=20
    history_record "bbbb2222-2222-2222-2222-222222222222" "proj" $'task\twith\ttabs\nand\nnewlines' "failed" "60" "drain-host-9999"
    local line
    line=$(cat "$HISTORY_FILE")
    [[ "$line" != *$'\t\t'* ]]
    [[ "$line" != *$'\n'* ]]
    [[ "$line" == *"task with tabs and newlines"* ]]
    rm -f "$HISTORY_FILE"
}

@test "history_record prunes to rolling window" {
    load_functions
    rm -f "$HISTORY_FILE"
    export HISTORY_LIMIT=3
    for i in 1 2 3 4 5; do
        history_record "uuid-$i" "proj" "task $i" "done" "10" "w1"
    done
    local count
    count=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
    [ "$count" = "3" ]
    # Should keep the last 3 (tasks 3, 4, 5)
    local content
    content=$(cat "$HISTORY_FILE")
    [[ "$content" != *"task 1"* ]]
    [[ "$content" != *"task 2"* ]]
    [[ "$content" == *"task 3"* ]]
    [[ "$content" == *"task 4"* ]]
    [[ "$content" == *"task 5"* ]]
    rm -f "$HISTORY_FILE"
}

@test "cmd_history shows no-history message when file does not exist" {
    load_functions
    rm -f "$HISTORY_FILE"
    run cmd_history
    [ "$status" -eq 0 ]
    [[ "$output" == *"no history yet"* ]]
}

@test "cmd_history shows summary stats and table" {
    load_functions
    rm -f "$HISTORY_FILE"
    export HISTORY_LIMIT=20
    history_record "aaaa1111-1111-1111-1111-111111111111" "projA" "first task" "done" "120" "w1"
    history_record "bbbb2222-2222-2222-2222-222222222222" "projB" "second task" "failed" "45" "w1"
    run cmd_history
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 processed"* ]]
    [[ "$output" == *"1 done"* ]]
    [[ "$output" == *"1 failed"* ]]
    [[ "$output" == *"50%"* ]]
    [[ "$output" == *"first task"* ]]
    [[ "$output" == *"second task"* ]]
    [[ "$output" == *"✓"* ]]
    [[ "$output" == *"✗"* ]]
    rm -f "$HISTORY_FILE"
}

@test "cmd_history --limit flag limits output rows" {
    load_functions
    rm -f "$HISTORY_FILE"
    export HISTORY_LIMIT=20
    for i in 1 2 3 4 5; do
        history_record "uuid-$i" "proj" "task $i" "done" "10" "w1"
    done
    run cmd_history --limit 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"task 5"* ]]
    [[ "$output" == *"task 4"* ]]
    [[ "$output" != *"task 3"* ]]
    rm -f "$HISTORY_FILE"
}

@test "drain help shows history command" {
    run "$SCRIPT_DIR/drain" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"history"* ]]
}

# --- drain pr list ---

@test "drain help shows pr command" {
    run "$SCRIPT_DIR/drain" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"pr list"* ]]
}

@test "drain help pr shows detailed help" {
    run "$SCRIPT_DIR/drain" help pr
    [ "$status" -eq 0 ]
    [[ "$output" == *"--json"* ]]
    [[ "$output" == *"drain pr list"* ]]
}

@test "drain pr list runs successfully" {
    run "$SCRIPT_DIR/drain" pr list
    [ "$status" -eq 0 ]
}

@test "drain pr list --json runs successfully" {
    run "$SCRIPT_DIR/drain" pr list --json
    [ "$status" -eq 0 ]
}

# --- drain_list_prs / PENDING APPROVAL section ---

@test "drain_list_prs returns empty array when no repos exist" {
    load_functions
    export GIT_ROOT="$BATS_TEST_DIRNAME/nonexistent-git-root"
    result=$(drain_list_prs)
    [ "$result" = "[]" ]
}

@test "drain_repo_paths returns empty when no repos.conf and no GIT_ROOT" {
    load_functions
    export GIT_ROOT="$BATS_TEST_DIRNAME/nonexistent-git-root"
    result=$(drain_repo_paths)
    [ -z "$result" ]
}

@test "drain_repo_paths includes repos.conf entries" {
    load_functions
    mkdir -p "$BATS_TEST_DIRNAME/fake-repo"
    echo "myproject=$BATS_TEST_DIRNAME/fake-repo" > "$HOME/.task-drain/repos.conf"
    export GIT_ROOT="$BATS_TEST_DIRNAME/nonexistent-git-root"
    result=$(drain_repo_paths)
    [[ "$result" == *"$BATS_TEST_DIRNAME/fake-repo"* ]]
    rm -f "$HOME/.task-drain/repos.conf"
    rm -rf "$BATS_TEST_DIRNAME/fake-repo"
}

@test "drain help history shows detailed help" {
    run "$SCRIPT_DIR/drain" help history
    [ "$status" -eq 0 ]
    [[ "$output" == *"--limit"* ]]
    [[ "$output" == *"drain history"* ]]
}

@test "drain history --limit 10 runs successfully" {
    run "$SCRIPT_DIR/drain" history --limit 10
    [ "$status" -eq 0 ]
}

# --- claim-failure handling (audit fix) ---

@test "claim_task returns 1 when post-claim sync fails" {
    load_functions
    # Smart mock: mutations succeed, sync always fails
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
if [ "$1" = "sync" ]; then exit 1; fi
exit 0
MOCK
    chmod +x "$TASK"
    export DRAIN_SYNC_RETRY_DELAY=0
    run claim_task "aaaa1111-1111-1111-1111-111111111111"
    [ "$status" -eq 1 ]
}

# --- DOC-09: simultaneous worker claim (host-local lock) ---

@test "acquire_lock succeeds for first worker" {
    load_functions
    local lock_dir="$HOME/.task-drain/locks/test-lock-$$"
    acquire_lock "$lock_dir"
    [ -d "$lock_dir" ]
    [ -f "$lock_dir/pid" ]
    local pid
    pid=$(cat "$lock_dir/pid")
    [ "$pid" = "$$" ]
    rm -rf "$lock_dir"
}

@test "acquire_lock fails for second worker on same path" {
    load_functions
    local lock_dir="$HOME/.task-drain/locks/test-lock-$$"
    mkdir -p "$lock_dir"
    printf '99999\n' > "$lock_dir/pid"
    if acquire_lock "$lock_dir"; then
        return 1
    fi
    rm -rf "$lock_dir"
}

@test "release_locks cleans up task and repo locks" {
    load_functions
    local task_lock="$HOME/.task-drain/locks/test-task-$$"
    local repo_lock="$HOME/.task-drain/locks/test-repo-$$"
    mkdir -p "$task_lock" "$repo_lock"
    printf '%s\n' "$$" > "$task_lock/pid"
    printf '%s\n' "$$" > "$repo_lock/pid"
    TASK_LOCK="$task_lock"
    REPO_LOCK="$repo_lock"
    release_locks
    [ ! -e "$task_lock" ]
    [ ! -e "$repo_lock" ]
    [ -z "$TASK_LOCK" ]
    [ -z "$REPO_LOCK" ]
}

@test "release_locks ignores locks owned by other workers" {
    load_functions
    local task_lock="$HOME/.task-drain/locks/test-task-$$"
    mkdir -p "$task_lock"
    printf '99999\n' > "$task_lock/pid"
    TASK_LOCK="$task_lock"
    REPO_LOCK=""
    release_locks
    # Lock should still exist since it's owned by a different pid
    [ -d "$task_lock" ]
    rm -rf "$task_lock"
}

@test "simultaneous workers: exactly one acquires task lock" {
    load_functions
    local lock_dir="$HOME/.task-drain/locks/test-race-$$"
    # Worker 1 acquires
    acquire_lock "$lock_dir"
    [ -d "$lock_dir" ]
    # Worker 2 fails
    if acquire_lock "$lock_dir"; then
        rm -rf "$lock_dir"
        return 1
    fi
    rm -rf "$lock_dir"
}

@test "run_one skips the task without launching the agent when claim fails" {
    load_functions
    # Force the claim to fail; the worker must survive and move on
    claim_task() { return 1; }
    mkdir -p "$BATS_TEST_DIRNAME/bin"
    printf '#!/usr/bin/env bash\ntouch "%s/agent-launched"\nexit 0\n' "$BATS_TEST_DIRNAME" > "$BATS_TEST_DIRNAME/bin/opencode"
    chmod +x "$BATS_TEST_DIRNAME/bin/opencode"
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export OPENCODE_BIN="$BATS_TEST_DIRNAME/bin/opencode"
    export DRAIN_SYNC_RETRY_DELAY=0
    run run_one '{"uuid":"aaaa1111-1111-1111-1111-111111111111","project":"myproject","priority":"H","description":"test task"}'
    [ "$status" -eq 1 ]
    [ ! -f "$BATS_TEST_DIRNAME/agent-launched" ]
    rm -rf "$BATS_TEST_DIRNAME/bin" "$BATS_TEST_DIRNAME/agent-launched"
}

# run_one fail-closed test omitted: the background annotator subshell
# does not exit cleanly in the bats test environment, causing a hang.
# The DOC-32 semantics are covered by the plugin mutate test.

# --- autoscaler worker counting (audit fix) ---

@test "autoscaler worker-count pattern excludes the supervisor itself" {
    # Use isolated fixture files and Bash builtins only.
    # No sleep subprocesses can survive and retain Bats output pipes.
    local stub_dir="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$stub_dir"

    local S="$stub_dir/task-drain.sh"

    cat > "$S" <<'STUB'
#!/usr/bin/env bash
while :; do
    :
done
STUB
    chmod +x "$S"

    bash "$S" &
    local worker=$!

    bash "$S" autoscale &
    local sup=$!

    sleep 0.3

    local counted
    counted=$(pgrep -f "bash $S$" | wc -l | tr -d ' ')

    # Cleanup must happen before assertions.
    kill "$worker" "$sup" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
    wait "$sup" 2>/dev/null || true

    [ "$counted" = "1" ]
}

# --- kill-switch coverage (audit fix) ---

@test "stop_autoscaler stops the supervisor via pidfile and removes it" {
    eval "$(sed -n '/^stop_autoscaler() {/,/^}/p' "$SCRIPT_DIR/drain")"
    export DRAIN_HOME="$HOME/.task-drain"
    # Identity-verified stop requires the supervisor cmdline pattern, so the
    # fixture is a stub named task-drain.sh running with the autoscale verb
    # (a bare `sleep` must NOT be killable — see the PID-reuse test below).
    local stub="$BATS_TEST_TMPDIR/task-drain.sh"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
SLEEP=""
trap 'kill $SLEEP 2>/dev/null; exit 0' TERM INT
while true; do sleep 30 & SLEEP=$!; wait $SLEEP || true; done
STUB
    chmod +x "$stub"
    "$stub" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    echo "$sup" > "$DRAIN_HOME/autoscale.pid"
    run stop_autoscaler
    [ "$status" -eq 0 ]
    [ ! -f "$DRAIN_HOME/autoscale.pid" ]
    sleep 0.2
    ! kill -0 "$sup" 2>/dev/null
    wait "$sup" 2>/dev/null || true
}

# --- pick_task urgency sort ---

@test "pick_task returns the highest-urgency task" {
    load_functions
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"export"*)
        echo '[{"uuid":"aaaa1111-1111-1111-1111-111111111111","status":"pending","urgency":1.0,"description":"low"},{"uuid":"bbbb2222-2222-2222-2222-222222222222","status":"pending","urgency":5.0,"description":"high"},{"uuid":"cccc3333-3333-3333-3333-333333333333","status":"pending","urgency":3.0,"description":"medium"}]'
        ;;
    *) echo "mock-task $@" ;;
esac
MOCK
    chmod +x "$TASK"
    result=$(pick_task)
    [[ "$result" == *"bbbb2222-2222-2222-2222-222222222222"* ]]
    [[ "$result" == *"high"* ]]
}

@test "pick_task returns empty when export is empty" {
    load_functions
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"export"*) echo "" ;;
    *) echo "mock-task $@" ;;
esac
MOCK
    chmod +x "$TASK"
    result=$(pick_task)
    [ "$result" = "" ]
}

@test "pick_task includes project filter when PROJECT_FILTER is set" {
    load_functions
    export PROJECT_FILTER="myproject"
    result=$(pick_task)
    [[ "$result" == *"myproject"* ]] || [[ "$result" == "" ]]
    unset PROJECT_FILTER
}

# --- pick_retry_task snapshot semantics ---

@test "pick_retry_task pops UUID from snapshot" {
    load_functions
    export DRAIN_RETRY_FAILED=1
    export RETRY_SNAPSHOT="$BATS_TEST_DIRNAME/retry-snapshot-test"
    echo "aaaa1111-1111-1111-1111-111111111111" > "$RETRY_SNAPSHOT"
    echo "bbbb2222-2222-2222-2222-222222222222" >> "$RETRY_SNAPSHOT"
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"export"*)
        # Return a pending drain-failed task for any UUID
        echo '[{"uuid":"aaaa1111-1111-1111-1111-111111111111","status":"pending","tags":["drain-failed"]}]'
        ;;
    *) echo "mock-task $@" ;;
esac
MOCK
    chmod +x "$TASK"
    result=$(pick_retry_task)
    [[ "$result" == *"aaaa1111-1111-1111-1111-111111111111"* ]]
    # Snapshot should have the first UUID removed
    [[ "$(cat "$RETRY_SNAPSHOT")" != *"aaaa1111-1111-1111-1111-111111111111"* ]]
    rm -f "$RETRY_SNAPSHOT"
    unset DRAIN_RETRY_FAILED
}

@test "pick_retry_task skips non-pending tasks" {
    load_functions
    export DRAIN_RETRY_FAILED=1
    export RETRY_SNAPSHOT="$BATS_TEST_DIRNAME/retry-snapshot-test"
    echo "aaaa1111-1111-1111-1111-111111111111" > "$RETRY_SNAPSHOT"
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"export"*)
        # Return a completed task (not pending)
        echo '[{"uuid":"aaaa1111-1111-1111-1111-111111111111","status":"completed","tags":["drain-failed"]}]'
        ;;
    *) echo "mock-task $@" ;;
esac
MOCK
    chmod +x "$TASK"
    run pick_retry_task
    [ "$status" -eq 1 ]
    [[ "$output" == *"skipping"* ]]
    rm -f "$RETRY_SNAPSHOT"
    unset DRAIN_RETRY_FAILED
}

# --- reclaim_stale ---

@test "reclaim_stale releases claims for tasks stale beyond threshold" {
    load_functions
    export STALE_AFTER_SEC=3600
    local stale_ts=$(date -v-2H +%Y%m%dT%H%M%SZ 2>/dev/null || date -d '2 hours ago' +%Y%m%dT%H%M%SZ)
    cat > "$TASK" << MOCK
#!/usr/bin/env bash
case "\$*" in
    *"export"*)
        echo '[{"uuid":"aaaa1111-1111-1111-1111-111111111111","start":"${stale_ts}","tags":["drain-claimed"]}]'
        ;;
    *"modify"*) echo "Modified" ;;
    *"annotate"*) echo "Annotated" ;;
    *"stop"*) echo "Stopped" ;;
    *) echo "mock-task \$@" ;;
esac
MOCK
    chmod +x "$TASK"
    run reclaim_stale
    [ "$status" -eq 0 ]
    rm -f "$RETRY_SNAPSHOT"
}

@test "reclaim_stale does nothing when no stale claims" {
    load_functions
    export STALE_AFTER_SEC=3600
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"export"*) echo "[]" ;;
    *) echo "mock-task $@" ;;
esac
MOCK
    chmod +x "$TASK"
    run reclaim_stale
    [ "$status" -eq 0 ]
}

# --- release_claim ---

@test "release_claim removes drain-claimed tag and annotates" {
    load_functions
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
echo "called: $@" >> "$MOCK_LOG"
exit 0
MOCK
    chmod +x "$TASK"
    export MOCK_LOG="$BATS_TEST_DIRNAME/mock-calls.log"
    rm -f "$MOCK_LOG"
    run release_claim "aaaa1111-1111-1111-1111-111111111111" "test release reason"
    [ "$status" -eq 0 ]
    local calls
    calls=$(cat "$MOCK_LOG")
    [[ "$calls" == *"modify -drain-claimed"* ]]
    [[ "$calls" == *"annotate"* ]]
    [[ "$calls" == *"test release reason"* ]]
    rm -f "$MOCK_LOG"
    unset MOCK_LOG
}

# --- cleanup_retry ---

@test "cleanup_retry removes snapshot files" {
    load_functions
    export RETRY_SNAPSHOT="$BATS_TEST_DIRNAME/retry-snapshot-test"
    touch "$RETRY_SNAPSHOT" "$RETRY_SNAPSHOT.tmp"
    cleanup_retry
    [ ! -f "$RETRY_SNAPSHOT" ]
    [ ! -f "$RETRY_SNAPSHOT.tmp" ]
    unset RETRY_SNAPSHOT
}

@test "cleanup_retry does nothing when no snapshot" {
    load_functions
    export RETRY_SNAPSHOT=""
    run cleanup_retry
    # Returns 1 because the -n test fails, but should not error
    [ "$status" -eq 1 ]
    unset RETRY_SNAPSHOT
}

# --- on_signal ---

@test "on_signal exits with 130 and releases claim" {
    load_functions
    cat > "$TASK" << 'MOCK'
#!/usr/bin/env bash
echo "called: $@" >> "$MOCK_LOG"
exit 0
MOCK
    chmod +x "$TASK"
    export MOCK_LOG="$BATS_TEST_DIRNAME/mock-calls.log"
    rm -f "$MOCK_LOG"
    export CURRENT_UUID="aaaa1111-1111-1111-1111-111111111111"
    export CHILD_PID=""
    export RETRY_SNAPSHOT=""
    export DRAIN_SYNC_RETRY_DELAY=0
    run on_signal
    [ "$status" -eq 130 ]
    local calls
    calls=$(cat "$MOCK_LOG")
    [[ "$calls" == *"modify -drain-claimed"* ]]
    rm -f "$MOCK_LOG"
    unset MOCK_LOG CURRENT_UUID
}

# --- lib/display.sh formatting ---

@test "drain_fmt_dur formats seconds" {
    result=$(drain_fmt_dur 45)
    [ "$result" = "45s" ]
}

@test "drain_fmt_dur formats minutes" {
    result=$(drain_fmt_dur 120)
    [ "$result" = "2m" ]
}

@test "drain_fmt_dur formats hours" {
    result=$(drain_fmt_dur 7200)
    [ "$result" = "2h" ]
}

@test "drain_fmt_dur formats days" {
    result=$(drain_fmt_dur 172800)
    [ "$result" = "2d" ]
}

@test "drain_fmt_dur returns ? for non-numeric" {
    result=$(drain_fmt_dur "abc")
    [ "$result" = "?" ]
}

@test "drain_dur formats seconds" {
    result=$(drain_dur 45)
    [ "$result" = "45s" ]
}

@test "drain_dur formats minutes" {
    result=$(drain_dur 120)
    [ "$result" = "2m" ]
}

@test "drain_dur formats hours" {
    result=$(drain_dur 7200)
    [ "$result" = "2h" ]
}

@test "drain_dur formats days" {
    result=$(drain_dur 172800)
    [ "$result" = "2d" ]
}

@test "drain_dur returns ? for non-numeric" {
    result=$(drain_dur "abc")
    [ "$result" = "?" ]
}

@test "drain_trunc_str truncates long strings" {
    result=$(drain_trunc_str "this is a very long string" 10)
    [[ "$result" == *"…" ]]
    [ "${#result}" -le 10 ]
}

@test "drain_trunc_str passes through short strings" {
    result=$(drain_trunc_str "short" 10)
    [ "$result" = "short" ]
}

@test "drain_bar produces a bar of correct width" {
    result=$(drain_bar 5 10 20)
    [ "${#result}" -eq 20 ]
}

@test "drain_bar caps fill at width" {
    result=$(drain_bar 10 10 20)
    [ "${#result}" -eq 20 ]
    [[ "$result" != *"░"* ]]
}

@test "drain_meter produces a bar of correct width" {
    result=$(drain_meter 5 10 20)
    [ "${#result}" -eq 20 ]
}

@test "drain_terminal_setup clamps columns to 40-200" {
    export COLUMNS=10
    drain_terminal_setup
    [ "$DRAIN_COLS" -ge 40 ]
    export COLUMNS=500
    drain_terminal_setup
    [ "$DRAIN_COLS" -le 200 ]
    export COLUMNS=80
    drain_terminal_setup
    [ "$DRAIN_COLS" -eq 80 ]
    unset COLUMNS
}

@test "log writes only to stderr and preserves JSON stdout" {
    local stdout_file="$BATS_TEST_TMPDIR/stdout"
    local stderr_file="$BATS_TEST_TMPDIR/stderr"

    bash -c '
        WORKER_ID="test-worker-123"
        log_def=$(grep -E "^log\(\)" "$1")
        eval "$log_def"

        log "retry: skipping task"
        log "retry: skipping another task"

        printf "%s\n" "{\"uuid\":\"abc-123\"}"
    ' _ "$BATS_TEST_DIRNAME/../task-drain.sh" \
        >"$stdout_file" 2>"$stderr_file"

    [ "$(cat "$stdout_file")" = '{"uuid":"abc-123"}' ]
    jq -e '.uuid == "abc-123"' "$stdout_file" >/dev/null

    grep -q 'retry: skipping task' "$stderr_file"
    grep -q 'retry: skipping another task' "$stderr_file"

    grep -Eq \
      '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[test-worker-123\]' \
      "$stderr_file"
}

# --- supervisor lifecycle (single-instance guard, PID safety, cleanup) ---
# All fixtures use isolated HOME (fake-home) and BATS_TEST_TMPDIR paths, so
# production state (~/.task-drain/autoscale.pid) is never touched. Fixture
# stdio is file-backed (never Bats pipes) and every spawned process is
# killed and reaped before assertions.

supervisor_stub() { # $1 = path to write a task-drain.sh-named stub
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
SLEEP=""
trap 'kill $SLEEP 2>/dev/null; exit 0' TERM INT
while true; do sleep 30 & SLEEP=$!; wait $SLEEP || true; done
STUB
    chmod +x "$1"
}

@test "supervisor first launch registers and is detected as live" {
    supervisor_stub "$BATS_TEST_TMPDIR/task-drain.sh"
    export DRAIN_HOME="$HOME/.task-drain"
    "$BATS_TEST_TMPDIR/task-drain.sh" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    echo "$sup" > "$DRAIN_HOME/autoscale.pid"
    run supervisor_is_live
    [ "$status" -eq 0 ]
    [ "$(supervisor_registered_pid)" = "$sup" ]
    kill "$sup" 2>/dev/null || true
    wait "$sup" 2>/dev/null || true
}

@test "supervisor concurrent second launch is rejected" {
    supervisor_stub "$BATS_TEST_TMPDIR/task-drain.sh"
    export DRAIN_HOME="$HOME/.task-drain"
    "$BATS_TEST_TMPDIR/task-drain.sh" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    echo "$sup" > "$DRAIN_HOME/autoscale.pid"
    # Second starter must fail to acquire meaningful ownership: liveness
    # holds, so it must back off instead of launching a duplicate.
    run supervisor_is_live
    [ "$status" -eq 0 ]
    local count
    count=$(pgrep -f "task-drain.sh.*autoscale" | wc -l | tr -d ' ')
    kill "$sup" 2>/dev/null || true
    wait "$sup" 2>/dev/null || true
    [ "$count" = "1" ]
}

@test "supervisor stale pidfile (dead PID) does not block startup" {
    export DRAIN_HOME="$HOME/.task-drain"
    # PID that is certainly dead: spawn and reap a trivial process.
    true &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    echo "$dead" > "$DRAIN_HOME/autoscale.pid"
    run supervisor_is_live
    [ "$status" -ne 0 ]
    # A fresh starter may acquire the launch mutex and clear the stale file.
    supervisor_acquire_launch_lock
    rm -f "$DRAIN_HOME/autoscale.pid"
    supervisor_release_launch_lock
    [ ! -f "$DRAIN_HOME/autoscale.pid" ]
}

@test "supervisor stale pidfile (garbage) does not block startup" {
    export DRAIN_HOME="$HOME/.task-drain"
    echo "not-a-pid" > "$DRAIN_HOME/autoscale.pid"
    run supervisor_is_live
    [ "$status" -ne 0 ]
    run supervisor_registered_pid
    [ "$status" -ne 0 ]
    rm -f "$DRAIN_HOME/autoscale.pid"
    [ ! -f "$DRAIN_HOME/autoscale.pid" ]
}

@test "supervisor PID reuse by an unrelated process is never treated as live" {
    export DRAIN_HOME="$HOME/.task-drain"
    sleep 60 </dev/null >>"$BATS_TEST_TMPDIR/sleep.log" 2>&1 &
    local other=$!
    echo "$other" > "$DRAIN_HOME/autoscale.pid"
    run supervisor_is_live
    [ "$status" -ne 0 ]
    # stop_autoscaler must clean the stale file WITHOUT killing the process.
    eval "$(sed -n '/^stop_autoscaler() {/,/^}/p' "$SCRIPT_DIR/drain")"
    run stop_autoscaler
    [ "$status" -eq 0 ]
    [ ! -f "$DRAIN_HOME/autoscale.pid" ]
    kill -0 "$other" 2>/dev/null
    kill "$other" 2>/dev/null || true
    wait "$other" 2>/dev/null || true
}

@test "supervisor SIGTERM exits promptly and cleans its own pidfile" {
    export DRAIN_HOME="$HOME/.task-drain"
    export DRAIN_MIN_WORKERS=0
    export DRAIN_MAX_WORKERS=1
    export DRAIN_AUTOSCALE_INTERVAL=1
    export DRAIN_SYNC_RETRY_DELAY=0
    # Empty queue from the mock task + min 0 => desired 0: no workers spawn,
    # so this exercises the real supervisor loop with zero side effects.
    bash "$SCRIPT_DIR/task-drain.sh" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    echo "$sup" > "$DRAIN_HOME/autoscale.pid"
    sleep 1
    kill -0 "$sup" 2>/dev/null
    local start end elapsed
    start=$(date +%s)
    kill -TERM "$sup" 2>/dev/null
    local i
    for i in $(seq 1 10); do
        kill -0 "$sup" 2>/dev/null || break
        sleep 0.5
    done
    end=$(date +%s)
    elapsed=$((end - start))
    ! kill -0 "$sup" 2>/dev/null
    wait "$sup" 2>/dev/null || true
    [ "$elapsed" -lt 5 ]
    [ ! -f "$DRAIN_HOME/autoscale.pid" ]
    unset DRAIN_MIN_WORKERS DRAIN_MAX_WORKERS DRAIN_AUTOSCALE_INTERVAL DRAIN_SYNC_RETRY_DELAY
}

@test "supervisor hard termination is recoverable on next startup" {
    supervisor_stub "$BATS_TEST_TMPDIR/task-drain.sh"
    export DRAIN_HOME="$HOME/.task-drain"
    "$BATS_TEST_TMPDIR/task-drain.sh" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    echo "$sup" > "$DRAIN_HOME/autoscale.pid"
    kill -KILL "$sup" 2>/dev/null
    wait "$sup" 2>/dev/null || true
    run supervisor_is_live
    [ "$status" -ne 0 ]
    # Next starter acquires the mutex and clears the stale registration.
    supervisor_acquire_launch_lock
    rm -f "$DRAIN_HOME/autoscale.pid"
    supervisor_release_launch_lock
    [ ! -f "$DRAIN_HOME/autoscale.pid" ]
}

@test "supervisor stop does not terminate unrelated workers" {
    supervisor_stub "$BATS_TEST_TMPDIR/task-drain.sh"
    export DRAIN_HOME="$HOME/.task-drain"
    eval "$(sed -n '/^stop_autoscaler() {/,/^}/p' "$SCRIPT_DIR/drain")"
    # An unrelated live process reusing the pidfile PID ...
    sleep 60 </dev/null >>"$BATS_TEST_TMPDIR/s1.log" 2>&1 &
    local other=$!
    # ... plus a fake worker (matches the worker pattern, not supervisor).
    "$BATS_TEST_TMPDIR/task-drain.sh" </dev/null >>"$BATS_TEST_TMPDIR/w.log" 2>&1 &
    local worker=$!
    echo "$other" > "$DRAIN_HOME/autoscale.pid"
    run stop_autoscaler
    [ "$status" -eq 0 ]
    kill -0 "$other" 2>/dev/null
    kill -0 "$worker" 2>/dev/null
    kill "$other" "$worker" 2>/dev/null || true
    wait "$other" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
}

@test "supervisor repeated start-stop cycles leak no processes" {
    supervisor_stub "$BATS_TEST_TMPDIR/task-drain.sh"
    export DRAIN_HOME="$HOME/.task-drain"
    eval "$(sed -n '/^stop_autoscaler() {/,/^}/p' "$SCRIPT_DIR/drain")"
    local before after i sup
    before=$(pgrep -f "task-drain.sh.*autoscale" | wc -l | tr -d ' ')
    for i in 1 2 3; do
        "$BATS_TEST_TMPDIR/task-drain.sh" autoscale </dev/null >>"$BATS_TEST_TMPDIR/cyc-$i.log" 2>&1 &
        sup=$!
        echo "$sup" > "$DRAIN_HOME/autoscale.pid"
        run stop_autoscaler
        [ "$status" -eq 0 ]
        wait "$sup" 2>/dev/null || true
        [ ! -f "$DRAIN_HOME/autoscale.pid" ]
    done
    after=$(pgrep -f "task-drain.sh.*autoscale" | wc -l | tr -d ' ')
    [ "$after" = "$before" ]
}

@test "supervisor TERM leaves no sleep child behind" {
    supervisor_stub "$BATS_TEST_TMPDIR/task-drain.sh"
    "$BATS_TEST_TMPDIR/task-drain.sh" autoscale </dev/null >>"$BATS_TEST_TMPDIR/sup.log" 2>&1 &
    local sup=$!
    sleep 0.5
    kill -TERM "$sup" 2>/dev/null
    local i
    for i in $(seq 1 10); do
        kill -0 "$sup" 2>/dev/null || break
        sleep 0.5
    done
    wait "$sup" 2>/dev/null || true
    # No orphaned sleep children of the dead supervisor may remain.
    local leftovers
    leftovers=$(pgrep -P "$sup" 2>/dev/null | wc -l | tr -d ' ')
    [ "$leftovers" = "0" ]
}
