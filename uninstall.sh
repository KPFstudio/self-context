#!/usr/bin/env bash
# uninstall.sh — Remove self-context from Claude Code
#
# Usage:
#   bash uninstall.sh [--yes] [--claude-home PATH]
#
# Options:
#   --yes              Skip confirmation prompts
#   --claude-home PATH Use PATH instead of ~/.claude (for testing)
#
# What this does:
#   1. Removes injected hooks from settings.json
#   2. Removes (or restores) the statusLine entry
#   3. Deletes installed script files
#   4. Does NOT delete backups (listed at end for manual cleanup)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
AUTO_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) AUTO_YES=true; shift ;;
    --claude-home)
      if [ -n "${2:-}" ]; then
        CLAUDE_HOME="$2"; shift 2
      else
        echo "Error: --claude-home requires a path" >&2; exit 1
      fi ;;
    --claude-home=*) CLAUDE_HOME="${1#--claude-home=}"; shift ;;
    *) shift ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; }
info() { printf "        %s\n" "$*"; }

SETTINGS="${CLAUDE_HOME}/settings.json"
HOOK_DEST="${CLAUDE_HOME}/hooks"
STATUSLINE_DEST="${CLAUDE_HOME}/statusline"
CTX_STATE_DIR="${CLAUDE_HOME}/.ctx-state"

echo ""
echo "self-context uninstaller"
echo "════════════════════════"
echo ""

if [ ! -f "$SETTINGS" ]; then
  warn "settings.json not found at ${SETTINGS}. Nothing to remove."
  exit 0
fi

echo "Will remove from: ${CLAUDE_HOME}"
echo "Files to delete:"
info "${HOOK_DEST}/inject-ctx.sh"
info "${HOOK_DEST}/inject-ctx-posttool.sh"
info "${STATUSLINE_DEST}/ctx-capture-wrapper.sh"
info "${CTX_STATE_DIR}/  (directory and contents)"
echo ""

if [ "$AUTO_YES" = false ]; then
  printf "Proceed? [y/N] "
  read -r confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ─── Backup settings.json before uninstall ────────────────────────────────────
if command -v jq >/dev/null 2>&1 && jq empty < "$SETTINGS" >/dev/null 2>&1; then
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  BACKUP="${SETTINGS}.bak-selfctx-uninstall-${TIMESTAMP}"
  cp "$SETTINGS" "$BACKUP"
  ok "Backed up settings.json → ${BACKUP}"
fi

# ─── Remove entries from settings.json ───────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  INJECT_CTX_PATH="${HOOK_DEST}/inject-ctx.sh"
  INJECT_CTX_POSTTOOL_PATH="${HOOK_DEST}/inject-ctx-posttool.sh"
  WRAPPER_PATH="${STATUSLINE_DEST}/ctx-capture-wrapper.sh"

  TMP=$(mktemp)

  # Remove UserPromptSubmit entries pointing to inject-ctx.sh
  jq --arg cmd "$INJECT_CTX_PATH" '
    if .hooks.UserPromptSubmit then
      .hooks.UserPromptSubmit = [
        .hooks.UserPromptSubmit[] |
        select((.hooks[]?.command // "") != $cmd)
      ]
    else . end
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

  # Remove PostToolUse entries pointing to inject-ctx-posttool.sh
  jq --arg cmd "$INJECT_CTX_POSTTOOL_PATH" '
    if .hooks.PostToolUse then
      .hooks.PostToolUse = [
        .hooks.PostToolUse[] |
        select((.hooks[]?.command // "") != $cmd)
      ]
    else . end
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

  # Remove or restore statusLine (M-1):
  # If settings.json has "selfctxPrevStatusLine" (saved by install.sh),
  # restore it.  Otherwise remove statusLine entirely.
  current_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
  if [ "$current_statusline" = "$WRAPPER_PATH" ] || \
     printf '%s' "$current_statusline" | grep -q 'selfctx\|self-context\|ctx-capture'; then
    prev_statusline=$(jq -r '.selfctxPrevStatusLine // empty' "$SETTINGS" 2>/dev/null || true)
    if [ -n "$prev_statusline" ]; then
      jq --arg prev "$prev_statusline" '
        .statusLine = {"type": "command", "command": $prev} |
        del(.selfctxPrevStatusLine)
      ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
      ok "Restored original statusLine: ${prev_statusline}"
    else
      jq 'del(.statusLine) | del(.selfctxPrevStatusLine)' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
      ok "Removed statusLine from settings.json (no previous value to restore)"
    fi
  else
    # Not ours — leave it, but still clean up the backup key if present
    jq 'del(.selfctxPrevStatusLine)' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
    warn "statusLine does not point to selfctx wrapper — leaving unchanged"
    info "Current: ${current_statusline:-<none>}"
  fi

  ok "settings.json cleaned up"
else
  warn "jq not available — skipping settings.json cleanup. Remove entries manually."
fi

# ─── Delete installed files ────────────────────────────────────────────────────
for f in \
  "${HOOK_DEST}/inject-ctx.sh" \
  "${HOOK_DEST}/inject-ctx-posttool.sh" \
  "${STATUSLINE_DEST}/ctx-capture-wrapper.sh"; do
  if [ -f "$f" ]; then
    rm "$f"
    ok "Removed ${f}"
  else
    info "Not found (skipped): ${f}"
  fi
done

# Remove ctx-state directory
if [ -d "$CTX_STATE_DIR" ]; then
  rm -rf "$CTX_STATE_DIR"
  ok "Removed ${CTX_STATE_DIR}/"
fi

# ─── List remaining backups ───────────────────────────────────────────────────
echo ""
BACKUPS=$(ls "${CLAUDE_HOME}/settings.json.bak-selfctx-"* 2>/dev/null || true)
if [ -n "$BACKUPS" ]; then
  info "Backups (not deleted — review and remove manually):"
  while IFS= read -r b; do
    info "  ${b}"
  done <<< "$BACKUPS"
  info ""
  info "To restore: cp <backup> ${SETTINGS}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "self-context uninstalled."
info "Restart Claude Code to apply."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
