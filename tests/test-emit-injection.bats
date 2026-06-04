#!/usr/bin/env bats
# tests/test-emit-injection.bats
# Tests for core/emit-injection.sh

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  EMIT="${REPO_ROOT}/core/emit-injection.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# ─── Positive cases ───────────────────────────────────────────────────────────

@test "emit-injection: ctx present -> outputs UserPromptSubmit JSON" {
  f="${TMPDIR_TEST}/ctx-state"
  printf 'ctx:87%%' > "$f"
  run bash "$EMIT" "$f" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Must be valid JSON
  printf '%s' "$output" | jq empty
  # hookEventName must be UserPromptSubmit
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event" = "UserPromptSubmit" ]
  # additionalContext must contain ctx:87%
  ctx_in_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_in_msg" == *"ctx:87%"* ]]
}

@test "emit-injection: ctx present -> PostToolUse JSON" {
  f="${TMPDIR_TEST}/ctx-state"
  printf 'ctx:42%%' > "$f"
  run bash "$EMIT" "$f" "PostToolUse"
  [ "$status" -eq 0 ]
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event" = "PostToolUse" ]
  ctx_in_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_in_msg" == *"ctx:42%"* ]]
}

@test "emit-injection: PostToolUse message contains Sub-agent wording" {
  f="${TMPDIR_TEST}/ctx-state"
  printf 'ctx:55%%' > "$f"
  run bash "$EMIT" "$f" "PostToolUse"
  [ "$status" -eq 0 ]
  ctx_in_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_in_msg" == *"Sub-agent"* ]]
}

@test "emit-injection: additionalContext contains 'remaining'" {
  f="${TMPDIR_TEST}/ctx-state"
  printf 'ctx:75%%' > "$f"
  run bash "$EMIT" "$f" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  ctx_in_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_in_msg" == *"remaining"* ]]
}

@test "emit-injection: additionalContext does NOT say 'invert'" {
  # ctx value direction: remaining means high = good. Verify no inversion language.
  f="${TMPDIR_TEST}/ctx-state"
  printf 'ctx:75%%' > "$f"
  run bash "$EMIT" "$f" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  ctx_in_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  # "do not invert" is acceptable; bare "invert it" without negation is not
  # The actual text says "do not invert it" which is fine
  [[ "$ctx_in_msg" != *"invert it. "* ]] || [[ "$ctx_in_msg" == *"do not invert"* ]]
}

# ─── Negative / silent-exit cases ─────────────────────────────────────────────

@test "emit-injection: file missing -> no output, exit 0" {
  run bash "$EMIT" "${TMPDIR_TEST}/nonexistent" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit-injection: file empty -> no output, exit 0" {
  f="${TMPDIR_TEST}/empty"
  touch "$f"
  run bash "$EMIT" "$f" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit-injection: no args -> no output, exit 0" {
  run bash "$EMIT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit-injection: invalid format (not ctx:NN%) -> no output, exit 0" {
  f="${TMPDIR_TEST}/bad"
  printf 'garbage_value' > "$f"
  run bash "$EMIT" "$f" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit-injection: output JSON is valid jq-parseable JSON" {
  f="${TMPDIR_TEST}/ctx-state"
  printf 'ctx:63%%' > "$f"
  run bash "$EMIT" "$f" "UserPromptSubmit"
  [ "$status" -eq 0 ]
  # jq empty exits 0 for valid JSON
  run jq empty <<< "$output"
  [ "$status" -eq 0 ]
}
