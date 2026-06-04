#!/usr/bin/env bash
# adapters/codex/hook-injector.sh
#
# Codex CLI hook adapter for self-context.
#
# How it works:
#   Codex CLI does NOT pass context_window.remaining_percentage in hook stdin.
#   Instead, each hook invocation includes a `transcript_path` pointing to a
#   rollout JSONL file. The last `token_count` event in that file contains:
#     payload.info.last_token_usage.total_tokens  (input + output for current turn)
#     payload.info.model_context_window
#
#   The formula matches the Codex TUI's context-remaining display exactly
#   (verified from openai/codex source: codex-rs/tui/src/token_usage.rs):
#
#     BASELINE = 12000
#     effective_window = model_context_window - BASELINE
#     used             = max(total_tokens - BASELINE, 0)
#     remaining        = max(effective_window - used, 0) / effective_window * 100
#
# ⚠️  total_token_usage (cumulative session total) is NOT used.
#     Only last_token_usage.total_tokens (current context size) is correct.
#
# ⚠️  input_tokens alone is NOT used. The TUI uses total_tokens from
#     last_token_usage (= input_tokens + output_tokens for the current turn),
#     not just input_tokens. Using input_tokens alone underestimates usage
#     by ~2-4 percentage points.
#
# Hook stdin fields (Codex CLI):
#   session_id, transcript_path, cwd, hook_event_name, model
#
# Output format (same as Claude Code adapter):
#   { "hookSpecificOutput": { "hookEventName": "...", "additionalContext": "..." } }
#   Silent exit 0 when no data is available.
#
# Requires: jq, bash

input=$(cat)

CTX_STATE_DIR="${SELFCTX_CTX_STATE_DIR:-$HOME/.claude/.ctx-state}"
CORE_DIR="${SELFCTX_CORE_DIR:-$(dirname "$0")/../../core}"

# jq is required for transcript parsing
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Parse hook stdin
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
hook_event_name=$(printf '%s' "$input" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)

# No transcript path → cannot compute remaining → silent exit
[ -z "$transcript_path" ] && exit 0
[ -f "$transcript_path" ] || exit 0

# Extract the LAST token_count event from the rollout JSONL
# Event structure:
#   { "type": "event_msg", "payload": { "type": "token_count",
#     "info": { "last_token_usage": { "input_tokens": N }, "model_context_window": M } } }
#
# NOTE: total_token_usage is intentionally ignored (cumulative, may exceed window).
last_token_count=$(grep '"type":"token_count"' "$transcript_path" 2>/dev/null | tail -1)

# Fallback: grep without quotes collapsed (some serializations have spaces)
if [ -z "$last_token_count" ]; then
  last_token_count=$(grep '"type": *"token_count"' "$transcript_path" 2>/dev/null | tail -1)
fi

[ -z "$last_token_count" ] && exit 0

total_tokens=$(printf '%s' "$last_token_count" | \
  jq -r '.payload.info.last_token_usage.total_tokens // empty' 2>/dev/null)
model_context_window=$(printf '%s' "$last_token_count" | \
  jq -r '.payload.info.model_context_window // empty' 2>/dev/null)

# Validate numeric values
[ -z "$total_tokens" ] && exit 0
[ -z "$model_context_window" ] && exit 0
[ "$model_context_window" -eq 0 ] 2>/dev/null && exit 0

# Compute remaining percentage using the same formula as Codex TUI:
#   Source: codex-rs/tui/src/token_usage.rs :: percent_of_context_window_remaining()
#   BASELINE_TOKENS = 12000
#   effective_window = model_context_window - BASELINE
#   used             = max(total_tokens - BASELINE, 0)
#   remaining        = max(effective_window - used, 0) / effective_window * 100
# Use awk for floating-point (bash does integer arithmetic only)
remaining_pct=$(awk "BEGIN {
  baseline = 12000
  eff = $model_context_window - baseline
  if (eff <= 0) { print 0; exit }
  used = $total_tokens - baseline
  if (used < 0) used = 0
  rem = eff - used
  if (rem < 0) rem = 0
  pct = (rem / eff) * 100
  if (pct > 100) pct = 100
  printf \"%.0f\", pct
}" 2>/dev/null)

[ -z "$remaining_pct" ] && exit 0

ctx="ctx:${remaining_pct}%"

# Persist to ctx-state for cross-hook consistency
{
  mkdir -p "$CTX_STATE_DIR"
  printf '%s' "$ctx" > "${CTX_STATE_DIR}/${session_id:-default}"
} 2>/dev/null || true

# Delegate emission to core
exec bash "${CORE_DIR}/emit-injection.sh" "${CTX_STATE_DIR}/${session_id:-default}" "$hook_event_name"
