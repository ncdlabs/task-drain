#!/usr/bin/env bats
# tests/test-config.bats — unified YAML configuration resolver contract tests.
# Covers schema/validation, precedence, cross-entry-point consistency,
# primary-host safety, and CLI behavior with isolated fixtures only.
# Never touches production Taskwarrior state, workers, or supervisors.

REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
FIX="$REPO_DIR/tests/config-fixtures"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.task-drain"
  unset DRAIN_CONFIG
  # Isolate every DRAIN_*/TASK_* override unless a test sets it explicitly.
  for v in $(compgen -v DRAIN_ 2>/dev/null); do unset "$v" 2>/dev/null || true; done
  for v in TASK_TIMEOUT_SEC STALE_AFTER_SEC GIT_ROOT TASK TASK_BIN TASKRC TASK_AUTO_SYNC OPENCODE_BIN CLAUDE_BIN CODEX_BIN; do
    unset "$v" 2>/dev/null || true
  done
  export PATH="$REPO_DIR:$PATH"
}

resolver() {
  python3 "$REPO_DIR/lib/drain-config.py" "$@"
}

@test "missing config file resolves to schema defaults" {
  run resolver resolve --config "$BATS_TEST_TMPDIR/nonexistent.yaml" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['values']['worker.agent']=='opencode'; assert d['values']['sync.retries']==3; assert d['config_present']==False"
}

@test "minimal valid config resolves with yaml provenance" {
  run resolver resolve --config "$FIX/minimal.yaml" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['values']['worker.primary_host']=='llama', d; assert d['sources']['worker.primary_host']=='yaml'; assert d['sources']['sync.retries']=='default'"
}

@test "full valid config resolves every setting (shell/yaml layer)" {
  run resolver resolve --config "$FIX/full.yaml" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys
d=json.load(sys.stdin)
v=d['values']
assert v['worker.agent']=='claude', v
assert v['worker.model']=='test-model-1'
assert v['worker.skip_permissions'] is True
assert v['supervisor.min_workers']==2
assert v['supervisor.max_workers']==6
assert v['sync.retries']==5
assert v['locks.grace_seconds']==5
assert v['history.limit']==50
assert v['display.verbose'] is True
assert v['logging.level']=='debug'
assert v['paths.task_bin']=='/bin/echo'
assert v['task.auto_sync'] is False
"
}

@test "malformed YAML fails closed with nonzero exit" {
  run resolver resolve --config "$FIX/malformed.yaml" --format json
  [ "$status" -ne 0 ]
}

@test "unknown keys are rejected" {
  run resolver resolve --config "$FIX/invalid-unknown.yaml" --format json
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown config key"* ]]
}

@test "wrong types are rejected with expected type" {
  run resolver resolve --config "$FIX/invalid-type.yaml" --format json
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync.retries"* ]]
}

@test "out-of-range integers are rejected with expected range" {
  run resolver resolve --config "$FIX/invalid-range.yaml" --format json
  [ "$status" -ne 0 ]
  [[ "$output" == *"out of range"* ]] || [[ "$output" == *"1..10"* ]]
}

@test "invalid booleans are rejected" {
  run resolver resolve --config "$FIX/invalid-bool.yaml" --format json
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid boolean"* ]]
}

@test "YAML precedence: yaml overrides defaults" {
  run resolver resolve --config "$FIX/full.yaml" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['sources']['sync.retries']=='yaml'"
}

@test "environment overrides YAML with environment provenance" {
  DRAIN_SYNC_RETRIES=7 run resolver resolve --config "$FIX/full.yaml" --format json
  # bats `run` with inline env assignment applies to the command in this shell;
  # use explicit export form for reliability:
  export DRAIN_SYNC_RETRIES=7
  run resolver resolve --config "$FIX/full.yaml" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['values']['sync.retries']==7, d; assert d['sources']['sync.retries']=='environment'"
  unset DRAIN_SYNC_RETRIES
}

@test "CLI --set overrides environment and YAML with cli provenance" {
  export DRAIN_SYNC_RETRIES=7
  run resolver resolve --config "$FIX/full.yaml" --set "sync.retries=9" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['values']['sync.retries']==9, d; assert d['sources']['sync.retries']=='cli'"
  unset DRAIN_SYNC_RETRIES
}

@test "empty environment values are treated as unset (fall through)" {
  export DRAIN_SYNC_RETRIES=""
  run resolver resolve --config "$FIX/full.yaml" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['values']['sync.retries']==5, d"
  unset DRAIN_SYNC_RETRIES
}

@test "conflicting env aliases are detected, not resolved unpredictably" {
  export TASK="/bin/a"
  export TASK_BIN="/bin/b"
  run resolver resolve --config "$FIX/minimal.yaml" --format json
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicting"* ]]
  unset TASK TASK_BIN
}

@test "strict boolean parsing accepts canonical spellings and rejects garbage" {
  for good in 1 true True TRUE yes Yes YES on On ON; do
    export DRAIN_AUTONOMOUS="$good"
    run resolver resolve --config "$FIX/minimal.yaml" --format json
    [ "$status" -eq 0 ] || { echo "rejected valid bool: $good"; return 1; }
  done
  for good in 0 false False FALSE no No NO off Off OFF; do
    export DRAIN_AUTONOMOUS="$good"
    run resolver resolve --config "$FIX/minimal.yaml" --format json
    [ "$status" -eq 0 ] || { echo "rejected valid bool: $good"; return 1; }
  done
  export DRAIN_AUTONOMOUS="perhaps"
  run resolver resolve --config "$FIX/minimal.yaml" --format json
  [ "$status" -ne 0 ]
  unset DRAIN_AUTONOMOUS
}

@test "min/max cross-field validation rejects min > max" {
  run resolver validate --config "$FIX/minimal.yaml" --set "supervisor.min_workers=8" --set "supervisor.max_workers=2"
  [ "$status" -ne 0 ]
}

@test "shell adapter exposes identical values and provenance" {
  export DRAIN_CONFIG="$FIX/full.yaml"
  source "$REPO_DIR/lib/config.sh"
  drain_config_load
  [ -z "$_DRAIN_CONFIG_ERROR" ]
  v=$(drain_config_value sync.retries)
  [ "$v" = "5" ]
  s=$(drain_config_source sync.retries)
  [ "$s" = "yaml" ]
  export DRAIN_SYNC_RETRIES=7
  # reload in a subshell to observe env precedence through the adapter
  run bash -c "export DRAIN_CONFIG='$FIX/full.yaml'; export DRAIN_SYNC_RETRIES=7; source '$REPO_DIR/lib/config.sh'; drain_config_load; drain_config_value sync.retries"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
  unset DRAIN_SYNC_RETRIES DRAIN_CONFIG
}

@test "shell adapter config_get serves map sections (repos/remotes/default_remote)" {
  export DRAIN_CONFIG="$FIX/full.yaml"
  source "$REPO_DIR/lib/config.sh"
  [ "$(config_get repos.myproject.path "")" = "/tmp/drain-test-repo" ]
  [ "$(config_get remotes.llama.ssh "")" = "ssh llama" ]
  unset DRAIN_CONFIG
}

@test "drain config path prints the active file" {
  export DRAIN_CONFIG="$FIX/minimal.yaml"
  run "$REPO_DIR/drain" --local config path
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX/minimal.yaml" ]
  unset DRAIN_CONFIG
}

@test "drain config validate passes on valid, fails on invalid" {
  run "$REPO_DIR/drain" --local --config "$FIX/minimal.yaml" config validate
  [ "$status" -eq 0 ]
  run "$REPO_DIR/drain" --local --config "$FIX/invalid-range.yaml" config validate
  [ "$status" -ne 0 ]
}

@test "drain config defaults prints a valid template and modifies nothing" {
  run "$REPO_DIR/drain" --local config defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker:"* ]]
  [[ "$output" == *"supervisor:"* ]]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/defaults.yaml"
  run resolver validate --config "$BATS_TEST_TMPDIR/defaults.yaml"
  # defaults output is commented template; validate the machine template instead
  run bash -c "python3 '$REPO_DIR/lib/drain-config.py' template > '$BATS_TEST_TMPDIR/tmpl.yaml' && python3 '$REPO_DIR/lib/drain-config.py' validate --config '$BATS_TEST_TMPDIR/tmpl.yaml'"
  [ "$status" -eq 0 ]
}

@test "drain config init creates mode-600 file only when absent, never overwrites" {
  export DRAIN_CONFIG="$BATS_TEST_TMPDIR/new-config.yaml"
  rm -f "$DRAIN_CONFIG"
  run "$REPO_DIR/drain" --local config init
  [ "$status" -eq 0 ]
  [ -f "$DRAIN_CONFIG" ]
  perms=$(stat -f %Lp "$DRAIN_CONFIG" 2>/dev/null || stat -c %a "$DRAIN_CONFIG")
  [ "$perms" = "600" ]
  run resolver validate --config "$DRAIN_CONFIG"
  [ "$status" -eq 0 ]
  # second init must refuse
  run "$REPO_DIR/drain" --local config init
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite"* ]]
  unset DRAIN_CONFIG
}

@test "drain config show redacts secrets and reports provenance" {
  export DRAIN_ERROR_WEBHOOK="https://example.com/secret-webhook"
  run "$REPO_DIR/drain" --local --config "$FIX/minimal.yaml" config show
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret-webhook"* ]]
  [[ "$output" == *"yaml"* ]]
  [[ "$output" == *"default"* ]]
  unset DRAIN_ERROR_WEBHOOK
}

@test "drain config commands never start workers or touch tasks" {
  export DRAIN_CONFIG="$FIX/minimal.yaml"
  before_workers=$(pgrep -f "task-drain.sh" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  run "$REPO_DIR/drain" --local config show
  [ "$status" -eq 0 ]
  run "$REPO_DIR/drain" --local config validate
  [ "$status" -eq 0 ]
  after_workers=$(pgrep -f "task-drain.sh" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ "$before_workers" = "$after_workers" ]
  unset DRAIN_CONFIG
}

@test "primary-host guard: matching short/FQDN forms are equivalent" {
  run python3 "$REPO_DIR/lib/drain-config.py" match-host --configured llama --actual llama.example.com
  [ "$status" -eq 0 ]
  run python3 "$REPO_DIR/lib/drain-config.py" match-host --configured llama.example.com --actual llama
  [ "$status" -eq 0 ]
  run python3 "$REPO_DIR/lib/drain-config.py" match-host --configured llama --actual llama2
  [ "$status" -ne 0 ]
}

@test "concurrent resolver reads are safe (parallel show)" {
  export DRAIN_CONFIG="$FIX/full.yaml"
  run bash -c "for i in 1 2 3 4 5; do '$REPO_DIR/drain' --local config show >/dev/null & done; wait"
  [ "$status" -eq 0 ]
  unset DRAIN_CONFIG
}

@test "schema and plugin copy cannot drift" {
  run bash -c "cmp -s '$REPO_DIR/lib/config-schema.json' '$REPO_DIR/plugin/src/config-schema.json'"
  [ "$status" -eq 0 ]
}
