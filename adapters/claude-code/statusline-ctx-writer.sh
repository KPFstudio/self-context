#!/usr/bin/env bash
# adapters/claude-code/statusline-ctx-writer.sh
#
# Claude Code statusLine wrapper — captures ctx:NN% and persists it to a file.
#
# How to use:
#   Set this script as your statusLine command in ~/.claude/settings.json:
#     "statusLine": { "type": "command", "command": "/path/to/statusline-ctx-writer.sh" }
#
# If you already have an existing statusLine command, set the environment variable:
#   SELFCTX_STATUSLINE_CMD=/path/to/your/existing/statusline.sh
# and this wrapper will delegate to it (Pattern A).
# If SELFCTX_STATUSLINE_CMD is unset, a minimal ctx-only statusline is output (Pattern B).
#
# Storage:
#   ctx:NN% is written to $SELFCTX_CTX_STATE_DIR/<session_id>
#   Default dir: ~/.claude/.ctx-state/
#   Override:    SELFCTX_CTX_STATE_DIR=/your/path
#
# This script does NOT count tokens. It only reads context_window.remaining_percentage
# from the stdin JSON that Claude Code provides to every statusLine command.

input=$(cat)

CTX_STATE_DIR="${SELFCTX_CTX_STATE_DIR:-$HOME/.claude/.ctx-state}"

# Extract session_id and remaining_percentage from stdin JSON
# (jq may be absent — guard with fallback)
if command -v jq >/dev/null 2>&1; then
  sid=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)
  ctx_remaining=$(printf '%s' "$input" | jq -r '.context_window.remaining_percentage // empty' 2>/dev/null)
else
  sid="default"
  ctx_remaining=""
fi

# --- Pattern A: delegate to existing statusLine command ---
# M-4: Use `sh -c` so the command string can contain arguments, env prefixes,
# shell operators, or any other syntax — not just a plain executable path.
if [ -n "${SELFCTX_STATUSLINE_CMD:-}" ]; then
  output=$(printf '%s' "$input" | sh -c "$SELFCTX_STATUSLINE_CMD" 2>/dev/null)

  # Extract ctx:NN% from the existing command's output (it may already contain it)
  ctx_from_output=$(printf '%s' "$output" | grep -oE 'ctx:[0-9]+%' | head -1)

  # Persist whichever value we have
  {
    if [ -n "$ctx_from_output" ]; then
      ctx="$ctx_from_output"
    elif [ -n "$ctx_remaining" ]; then
      ctx_pct=$(printf '%.0f' "$ctx_remaining" 2>/dev/null)
      ctx="ctx:${ctx_pct}%"
    fi
    if [ -n "$ctx" ]; then
      mkdir -p "$CTX_STATE_DIR"
      printf '%s' "$ctx" > "${CTX_STATE_DIR}/${sid:-default}"
    fi
  } 2>/dev/null || true

  # Pass through the existing command's output unchanged
  printf '%s' "$output"
  exit 0
fi

# --- Pattern B: minimal ctx-only statusLine (no existing command) ---
{
  if [ -n "$ctx_remaining" ]; then
    ctx_pct=$(printf '%.0f' "$ctx_remaining" 2>/dev/null)
    ctx="ctx:${ctx_pct}%"
    mkdir -p "$CTX_STATE_DIR"
    printf '%s' "$ctx" > "${CTX_STATE_DIR}/${sid:-default}"
    # Output minimal statusline: just the ctx value
    printf '%s' "$ctx"
  fi
  # If ctx_remaining is empty (first turn / no API response yet), output nothing
} 2>/dev/null || true
