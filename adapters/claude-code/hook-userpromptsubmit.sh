#!/usr/bin/env bash
# adapters/claude-code/hook-userpromptsubmit.sh
#
# Claude Code UserPromptSubmit hook — injects ctx:NN% into additionalContext.
#
# Claude Code calls this script on every user prompt submission.
# stdin: JSON with at least { "session_id": "..." }
#
# Output:
#   If ctx-state file exists and is non-empty:
#     { "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": "..." } }
#   Otherwise: no output, exit 0 (silent — Claude Code treats this as a no-op)
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

# Delegate to core emit-injection
exec bash "${CORE_DIR}/emit-injection.sh" "$f" "UserPromptSubmit"
