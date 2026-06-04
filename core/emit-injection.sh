#!/usr/bin/env bash
# core/emit-injection.sh — CLI-agnostic core
#
# Reads a ctx-state file and emits the injection string to stdout.
# Takes no stdin; accepts file path as $1, hook event name as $2, and
# optional adapter name as $3 (e.g. "codex").
#
# Usage:
#   emit-injection.sh <ctx_state_file> <hook_event_name> [adapter]
#
# Output:
#   If file exists and is non-empty: JSON injection string to stdout
#   If file is missing or empty:     silent exit 0 (no output, no error)
#
# This script does NOT calculate tokens itself.
# It only reads a pre-written ctx:NN% value from a file.

CTX_STATE_FILE="${1:-}"
HOOK_EVENT_NAME="${2:-UserPromptSubmit}"
ADAPTER="${3:-}"

# No file path provided → silent exit
[ -z "$CTX_STATE_FILE" ] && exit 0

# File does not exist → silent exit
[ -f "$CTX_STATE_FILE" ] || exit 0

ctx=$(cat "$CTX_STATE_FILE" 2>/dev/null)

# Empty content → silent exit
[ -z "$ctx" ] && exit 0

# Validate format: must match ctx:NN%
if ! printf '%s' "$ctx" | grep -qE '^ctx:[0-9]+%$'; then
  exit 0
fi

# Build injection message based on event type and adapter
if [ "$HOOK_EVENT_NAME" = "PostToolUse" ]; then
  if [ "$ADAPTER" = "codex" ]; then
    msg="[Context self-awareness] Current statusline value: ${ctx} (remaining; higher = more room). This is REMAINING context — do not invert it. If remaining is low, checkpoint / handoff now."
  else
    msg="[Context self-awareness] Sub-agent completed. Current statusline value: ${ctx} (remaining; higher = more room). This is REMAINING context — do not invert it. If remaining is low, checkpoint / handoff now."
  fi
else
  msg="[Context self-awareness] Current statusline value: ${ctx} (remaining). This is REMAINING context (higher = more room left); do not invert it. If remaining is low, consider starting a new session / doing a handoff."
fi

# Emit injection JSON to stdout
# Requires jq; if unavailable, fall back to manual JSON construction
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ev "$HOOK_EVENT_NAME" --arg m "$msg" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $m}}'
else
  # jq unavailable: minimal safe fallback (escape double quotes in msg)
  escaped=$(printf '%s' "$msg" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' \
    "$HOOK_EVENT_NAME" "$escaped"
fi
