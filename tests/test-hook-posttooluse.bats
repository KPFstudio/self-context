#!/usr/bin/env bats
# tests/test-hook-posttooluse.bats
# Tests for adapters/claude-code/hook-posttooluse.sh

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  HOOK="${REPO_ROOT}/adapters/claude-code/hook-posttooluse.sh"

  FAKE_HOME="$(mktemp -d)"
  CTX_STATE_DIR="${FAKE_HOME}/.claude/.ctx-state"
  mkdir -p "$CTX_STATE_DIR"

  export SELFCTX_CTX_STATE_DIR="$CTX_STATE_DIR"
  export SELFCTX_CORE_DIR="${REPO_ROOT}/core"
}

teardown() {
  rm -rf "$FAKE_HOME"
  unset SELFCTX_CTX_STATE_DIR SELFCTX_CORE_DIR
}

make_input() {
  local sid="${1:-test-session-ptu}"
  printf '{"session_id":"%s","tool_name":"Agent"}' "$sid"
}

# ─── Positive cases ───────────────────────────────────────────────────────────

@test "hook-ptu: ctx present -> hookEventName is PostToolUse" {
  sid="ptu-session-1"
  printf 'ctx:72%%' > "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event" = "PostToolUse" ]
}

@test "hook-ptu: ctx present -> additionalContext contains ctx:72%" {
  sid="ptu-session-ctx"
  printf 'ctx:72%%' > "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:72%"* ]]
}

@test "hook-ptu: additionalContext contains Sub-agent wording" {
  sid="ptu-subagent"
  printf 'ctx:60%%' > "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"Sub-agent"* ]]
}

@test "hook-ptu: additionalContext contains 'remaining'" {
  sid="ptu-remaining"
  printf 'ctx:45%%' > "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"remaining"* ]]
}

@test "hook-ptu: output is valid JSON" {
  sid="ptu-json"
  printf 'ctx:55%%' > "${CTX_STATE_DIR}/${sid}"
  output=$(printf '%s' "$(make_input $sid)" | bash "$HOOK")
  printf '%s' "$output" | jq empty
}

@test "hook-ptu: default fallback when session file absent" {
  printf 'ctx:30%%' > "${CTX_STATE_DIR}/default"
  run bash -c "printf '%s' '$(make_input unknown-ptu)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ─── Negative / silent cases ──────────────────────────────────────────────────

@test "hook-ptu: no ctx-state file -> no output, exit 0" {
  run bash -c "printf '%s' '$(make_input noptu)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook-ptu: empty ctx-state file -> no output, exit 0" {
  sid="ptu-empty"
  touch "${CTX_STATE_DIR}/${sid}"
  run bash -c "printf '%s' '$(make_input $sid)' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
