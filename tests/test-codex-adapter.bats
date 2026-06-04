#!/usr/bin/env bats
# tests/test-codex-adapter.bats
# Tests for adapters/codex/hook-injector.sh
#
# Uses a sample rollout JSONL fixture to verify:
# - remaining percentage is computed using the TUI-identical formula
#   (source: codex-rs/tui/src/token_usage.rs :: percent_of_context_window_remaining)
# - uses last_token_usage.total_tokens (NOT input_tokens alone, NOT total_token_usage)
# - ctx:NN% is written to ctx-state and emitted via core
#
# TUI formula (BASELINE = 12000):
#   effective_window = model_context_window - BASELINE
#   used             = max(total_tokens - BASELINE, 0)
#   remaining        = max(effective_window - used, 0) / effective_window * 100

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  HOOK="${REPO_ROOT}/adapters/codex/hook-injector.sh"

  FAKE_HOME="$(mktemp -d)"
  CTX_STATE_DIR="${FAKE_HOME}/.ctx-state"
  TRANSCRIPT_DIR="${FAKE_HOME}/transcripts"
  mkdir -p "$CTX_STATE_DIR" "$TRANSCRIPT_DIR"

  export SELFCTX_CTX_STATE_DIR="$CTX_STATE_DIR"
  export SELFCTX_CORE_DIR="${REPO_ROOT}/core"
}

teardown() {
  rm -rf "$FAKE_HOME"
  unset SELFCTX_CTX_STATE_DIR SELFCTX_CORE_DIR
}

# Build a minimal rollout JSONL transcript with a token_count event.
# Args: input_tokens model_context_window [cumulative_total_input_tokens]
# The fixture sets output_tokens=512, so last_token_usage.total_tokens = input_tokens + 512.
# cumulative_total_input_tokens defaults to input_tokens*3 (exceeds window) to expose the trap.
make_transcript() {
  local input_tokens="$1"
  local model_ctx="$2"
  local total_input="${3:-$((input_tokens * 3))}"  # cumulative > window to expose the trap
  local path="${TRANSCRIPT_DIR}/session.jsonl"

  # First event: some non-token-count event
  printf '{"type":"event_msg","payload":{"type":"agent_message","content":"hello"}}\n' > "$path"

  # Token count event (the one the adapter should read).
  # last_token_usage.total_tokens = input_tokens + 512 (= current context size used by TUI).
  # total_token_usage.input_tokens = cumulative (can exceed window; adapter must ignore it).
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%d,"cached_input_tokens":0,"output_tokens":512,"reasoning_output_tokens":0,"total_tokens":%d},"total_token_usage":{"input_tokens":%d},"model_context_window":%d}}}\n' \
    "$input_tokens" "$((input_tokens + 512))" "$total_input" "$model_ctx" >> "$path"

  echo "$path"
}

make_hook_input() {
  local transcript="$1"
  local sid="${2:-codex-test-session}"
  local event="${3:-UserPromptSubmit}"
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"%s","model":"gpt-5.5"}' \
    "$sid" "$transcript" "$event"
}

# ─── Positive cases ───────────────────────────────────────────────────────────

@test "codex-adapter: TUI-formula parity (input=91363,out=512,mcw=258400 → ctx:68%)" {
  # TUI formula: BASELINE=12000, effective=258400-12000=246400
  # total_tokens = 91363+512 = 91875
  # used = max(91875-12000,0) = 79875
  # remaining = max(246400-79875,0) = 166525
  # pct = round(166525/246400*100) = round(67.6%) = 68
  transcript=$(make_transcript 91363 258400)
  sid="codex-parity-test"
  input=$(make_hook_input "$transcript" "$sid")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:68%"* ]]
}

@test "codex-adapter: does NOT use total_token_usage (cumulative > window must not affect result)" {
  # total_token_usage.input_tokens=999999 (exceeds window) must be ignored.
  # Result must still be ctx:68%, same as the parity test.
  transcript=$(make_transcript 91363 258400 999999)
  sid="codex-no-total"
  input=$(make_hook_input "$transcript" "$sid")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:68%"* ]]
}

@test "codex-adapter: uses total_tokens not input_tokens from last_token_usage" {
  # Explicitly confirm output_tokens (512) contributes to the used count.
  # input=91363, total=91875; if adapter wrongly used input_tokens:
  #   wrong: 1 - 91363/258400 ≈ 65%
  # Correct TUI formula gives 68%. Any result != 65% confirms total_tokens path.
  transcript=$(make_transcript 91363 258400)
  sid="codex-total-not-input"
  input=$(make_hook_input "$transcript" "$sid")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  # Must NOT be the old (wrong) input_tokens-only value
  [[ "$ctx_msg" != *"ctx:65%"* ]]
  # Must match the correct TUI value
  [[ "$ctx_msg" == *"ctx:68%"* ]]
}

@test "codex-adapter: emits UserPromptSubmit hookEventName" {
  # input=50000, total=50512, mcw=200000
  # TUI: eff=188000, used=max(50512-12000,0)=38512, rem=149488, pct=round(79.5%)=80
  transcript=$(make_transcript 50000 200000)
  sid="codex-event-test"
  input=$(make_hook_input "$transcript" "$sid" "UserPromptSubmit")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event" = "UserPromptSubmit" ]
}

@test "codex-adapter: emits PostToolUse hookEventName when requested" {
  transcript=$(make_transcript 50000 200000)
  sid="codex-ptu-test"
  input=$(make_hook_input "$transcript" "$sid" "PostToolUse")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  event=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event" = "PostToolUse" ]
}

@test "codex-adapter: output JSON is valid" {
  # input=100000, total=100512, mcw=300000
  # TUI: eff=288000, used=88512, rem=199488, pct=round(69.3%)=69
  transcript=$(make_transcript 100000 300000)
  sid="codex-json-valid"
  input=$(make_hook_input "$transcript" "$sid")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  run jq empty <<< "$output"
  [ "$status" -eq 0 ]
}

@test "codex-adapter: high usage -> low remaining (input=190000,out=512,mcw=200000 → ctx:5%)" {
  # input=190000, total=190512, mcw=200000
  # TUI: eff=188000, used=max(190512-12000,0)=178512, rem=max(188000-178512,0)=9488
  # pct=round(9488/188000*100)=round(5.05%)=5
  transcript=$(make_transcript 190000 200000)
  sid="codex-low-remaining"
  input=$(make_hook_input "$transcript" "$sid")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  ctx_msg=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx_msg" == *"ctx:5%"* ]]
}

# ─── Negative / silent cases ──────────────────────────────────────────────────

@test "codex-adapter: no transcript_path -> no output, exit 0" {
  input='{"session_id":"x","hook_event_name":"UserPromptSubmit"}'
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex-adapter: transcript_path not found -> no output, exit 0" {
  input=$(make_hook_input "/nonexistent/path/transcript.jsonl" "x")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex-adapter: empty transcript -> no output, exit 0" {
  empty_transcript="${TRANSCRIPT_DIR}/empty.jsonl"
  touch "$empty_transcript"
  input=$(make_hook_input "$empty_transcript" "x")
  run bash -c "printf '%s' '$input' | bash \"$HOOK\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
