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
# Mock task command for testing
echo "mock-task $@"
MOCK
    chmod +x "$TASK"

    # Create fixture directories
    mkdir -p "$GIT_ROOT/myproject"
    mkdir -p "$HOME/.task-drain"
}

teardown() {
    rm -rf "$BATS_TEST_DIRNAME/fake-home"
    rm -rf "$BATS_TEST_DIRNAME/fixtures"
    rm -f "$TASK"
}

# Source shared libraries first
source "$SCRIPT_DIR/lib/display.sh"
source "$SCRIPT_DIR/lib/worker-detect.sh"

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

@test "drain autoscale --min 2 --max 4 parses correctly" {
    run "$SCRIPT_DIR/drain" autoscale --min 2 --max 4
    [[ "$output" != *"unexpected argument"* ]]
}
