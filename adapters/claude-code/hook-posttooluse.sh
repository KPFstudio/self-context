#!/usr/bin/env bash
# adapters/claude-code/hook-posttooluse.sh
#
# Claude Code PostToolUse hook — injects ctx:NN% after sub-agent completion.
#
# Claude Code calls this script after each tool use that matches the configured
# matcher (typically "Agent" and/or "Task" for sub-agent tool calls).
# stdin: JSON with at least { "session_id": "...", "tool_name": "..." }
#
# Output:
#   If ctx-state file exists and is non-empty:
#     { "hookSpecificOutput": { "hookEventName": "PostToolUse", "additionalContext": "..." } }
#   Otherwise: no output, exit 0 (silent — Claude Code treats this as a no-op)
#
# Matcher note (§7 of design report):
#   This env uses "Agent" as the tool name for sub-agents. Some Claude Code
#   versions use "Task". The settings-snippet.json registers both matchers so
#   this script fires on either. The script itself is matcher-agnostic.
#
# Storage path override: SELFCTX_CTX_STATE_DIR (default: ~/.claude/.ctx-state)

input=$(cat)

CTX_STATE_DIR="${SELFCTX_CTX_STATE_DIR:-$HOME/.claude/.ctx-state}"
CORE_DIR="${SELFCTX_CORE_DIR:-$(dirname "$0")/../../core}"

# Resolve session_id
if command -v jq >/dev/null 2>&1; then
  sid=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)
else
  sid="default"
fi

# Locate ctx-state file (session-specific → default fallback)
f="${CTX_STATE_DIR}/${sid}"
[ -f "$f" ] || f="${CTX_STATE_DIR}/default"
[ -f "$f" ] || exit 0

# Delegate to core emit-injection with PostToolUse event name
exec bash "${CORE_DIR}/emit-injection.sh" "$f" "PostToolUse"
