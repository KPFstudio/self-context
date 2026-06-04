#!/usr/bin/env bats
# tests/test-hook-userpromptsubmit.bats
# Tests for adapters/claude-code/hook-userpromptsubmit.sh

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  HOOK="${REPO_ROOT}/adapters/claude-code/hook-userpromptsubmit.sh"

  # Temp HOME to isolate from live ~/.claude
  FAKE_HOME="$(mktemp -d)"
  CTX_STATE_DIR="${FAKE_HOME}/.claude/.ctx-state"
  mkdir -p "$CTX_STATE_DIR"

  # Export so the hook uses our temp directory
  export SELFCTX_CTX_STATE_DIR="$CTX_STATE_DIR"
  export SELFCTX_CORE_DIR="${REPO_ROOT}/core"
}

teardown() {
  rm -rf "$FAKE_HOME"
  unset SELFCTX_CTX_STATE_DIR SELFCTX_CORE_DIR
}

make_input() {
  local sid="${1:-test-session-123}"
  printf '{"session_id":"%s"}' "$sid"
}

# ─── Positive cases ───────────────────────────────────────────────────────────

@test "hook-ups: ctx present -> valid JSON with UserPromptSubmit" {
  sid="test-session-abc"
  printf 'ctx:87%%' > "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s' "$output" | jq empty
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event" = "UserPromptSubmit" ]
}

@test "hook-ups: ctx present -> additionalContext contains ctx:87%" {
  sid="test-session-ctx"
  printf 'ctx:87%%' > "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:87%"* ]]
}

@test "hook-ups: default fallback file used when session file absent" {
  printf 'ctx:50%%' > "${CTX_STATE_DIR}/default"
  # Session file does NOT exist → should fall back to 'default'
  run bash -c "printf '%s' '$(make_input unknown-session)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:50%"* ]]
}

@test "hook-ups: output is valid JSON" {
  sid="session-json-check"
  printf 'ctx:63%%' > "${CTX_STATE_DIR}/${sid}"
  output=$(printf '%s' "$(make_input $sid)" | bash "$HOOK")
  printf '%s' "$output" | jq empty
}

# ─── Negative / silent cases ──────────────────────────────────────────────────

@test "hook-ups: no ctx-state file -> no output, exit 0" {
  # Neither session file nor default exists
  run bash -c "printf '%s' '$(make_input nosession)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook-ups: empty ctx-state file -> no output, exit 0" {
  sid="empty-session"
  touch "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook-ups: missing session_id in stdin -> uses default key" {
  printf 'ctx:33%%' > "${CTX_STATE_DIR}/default"
  run bash -c "printf '%s' '{}' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:33%"* ]]
}
