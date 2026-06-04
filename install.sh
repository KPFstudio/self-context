#!/usr/bin/env bash
# install.sh — Install self-context into Claude Code
#
# Usage:
#   bash install.sh [--yes] [--claude-home PATH]
#
# Options:
#   --yes              Skip confirmation prompts
#   --claude-home PATH Use PATH instead of ~/.claude (for testing)
#
# What this does:
#   1. Checks prerequisites (jq, Claude Code)
#   2. Backs up settings.json with a timestamp
#   3. Copies hook and statusline scripts into ~/.claude/
#   4. Merges settings.json additively (non-destructive, idempotent)
#   5. Reports what changed
#
# After running: restart Claude Code to activate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
AUTO_YES=false

# Parse args
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

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; }
info() { printf "        %s\n" "$*"; }

# ─── Prerequisite checks ──────────────────────────────────────────────────────
echo ""
echo "self-context installer"
echo "══════════════════════"
echo ""

# jq
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not found. Install with: brew install jq"
  exit 1
fi
ok "jq found: $(jq --version)"

# Claude Code
if ! command -v claude >/dev/null 2>&1; then
  warn "claude CLI not found in PATH. Make sure Claude Code is installed."
else
  ok "claude found: $(claude --version 2>/dev/null | head -1 || echo 'version unknown')"
fi

# settings.json
SETTINGS="${CLAUDE_HOME}/settings.json"
if [ ! -f "$SETTINGS" ]; then
  warn "settings.json not found at ${SETTINGS}."
  info "Creating a minimal settings.json ..."
  mkdir -p "$CLAUDE_HOME"
  echo '{}' > "$SETTINGS"
fi
ok "settings.json found: ${SETTINGS}"

# Validate settings.json is valid JSON
if ! jq empty < "$SETTINGS" >/dev/null 2>&1; then
  fail "settings.json is not valid JSON. Please fix it before installing."
  exit 1
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────
echo ""
echo "Will install into: ${CLAUDE_HOME}"
echo "Files to create:"
info "${CLAUDE_HOME}/hooks/inject-ctx.sh"
info "${CLAUDE_HOME}/hooks/inject-ctx-posttool.sh"
info "${CLAUDE_HOME}/statusline/ctx-capture-wrapper.sh"
info "${CLAUDE_HOME}/.ctx-state/  (directory)"
echo ""

if [ "$AUTO_YES" = false ]; then
  printf "Proceed? [y/N] "
  read -r confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ─── Backup settings.json ─────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP="${SETTINGS}.bak-selfctx-${TIMESTAMP}"
cp "$SETTINGS" "$BACKUP"
ok "Backed up settings.json → ${BACKUP}"

# ─── Copy scripts ─────────────────────────────────────────────────────────────
HOOK_DEST="${CLAUDE_HOME}/hooks"
STATUSLINE_DEST="${CLAUDE_HOME}/statusline"
CTX_STATE_DIR="${CLAUDE_HOME}/.ctx-state"

mkdir -p "$HOOK_DEST" "$STATUSLINE_DEST" "$CTX_STATE_DIR"

# Determine install dir for absolute paths in settings.json
INSTALL_DIR="$SCRIPT_DIR"

# Hook scripts
cp "${INSTALL_DIR}/adapters/claude-code/hook-userpromptsubmit.sh" \
   "${HOOK_DEST}/inject-ctx.sh"
cp "${INSTALL_DIR}/adapters/claude-code/hook-posttooluse.sh" \
   "${HOOK_DEST}/inject-ctx-posttool.sh"
chmod +x "${HOOK_DEST}/inject-ctx.sh" "${HOOK_DEST}/inject-ctx-posttool.sh"
ok "Installed hook scripts → ${HOOK_DEST}/"

# Wire SELFCTX_CORE_DIR and SELFCTX_CTX_STATE_DIR into installed hooks unconditionally.
# The source adapter files already have `CORE_DIR="${SELFCTX_CORE_DIR:-...}"` as a
# runtime fallback, which means grep-based "skip if already present" would erroneously
# skip the export injection every time.  Instead we always inject the resolved absolute
# paths directly after the shebang so the installed hook can locate emit-injection.sh
# regardless of where it was copied.
CORE_ABS="${INSTALL_DIR}/core"
for f in "${HOOK_DEST}/inject-ctx.sh" "${HOOK_DEST}/inject-ctx-posttool.sh"; do
  # Always (re-)inject export lines after the shebang — idempotent via temp file
  tmp=$(mktemp)
  head -1 "$f" > "$tmp"
  printf 'export SELFCTX_CORE_DIR="%s"\n' "$CORE_ABS" >> "$tmp"
  printf 'export SELFCTX_CTX_STATE_DIR="%s"\n' "$CTX_STATE_DIR" >> "$tmp"
  # Skip any pre-existing export lines for these two vars so we don't duplicate
  grep -v '^export SELFCTX_CORE_DIR=' "$f" | grep -v '^export SELFCTX_CTX_STATE_DIR=' | tail -n +2 >> "$tmp"
  mv "$tmp" "$f"
  chmod +x "$f"
done

# Statusline wrapper — set SELFCTX_CORE_DIR and handle existing statusLine
WRAPPER_DEST="${STATUSLINE_DEST}/ctx-capture-wrapper.sh"

# Capture existing statusLine command (if any, and not already ours).
# We store it in two places:
#   1. SELFCTX_STATUSLINE_CMD baked into the wrapper (for delegation at runtime)
#   2. settings.json key "selfctxPrevStatusLine" (for uninstall restoration)
# M-4: we do NOT assume the existing command is a plain path.
#   It may contain spaces, arguments, or shell syntax.
#   We delegate via `sh -c "$SELFCTX_STATUSLINE_CMD"` inside the wrapper,
#   which handles arbitrary command strings safely.
existing_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
SAVE_EXISTING=false
if [ -n "$existing_statusline" ] && \
   [ "$existing_statusline" != "$WRAPPER_DEST" ] && \
   ! printf '%s' "$existing_statusline" | grep -q 'selfctx\|self-context\|ctx-capture'; then
  info "Existing statusLine detected: ${existing_statusline}"
  info "Will be preserved via SELFCTX_STATUSLINE_CMD and restored on uninstall."
  SAVE_EXISTING=true
fi

# Save original statusLine into settings.json for uninstall to restore (M-1)
if [ "$SAVE_EXISTING" = true ]; then
  TMP=$(mktemp)
  jq --arg prev "$existing_statusline" '
    .selfctxPrevStatusLine = $prev
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  ok "Saved original statusLine → selfctxPrevStatusLine"
fi

# Install the wrapper with env vars baked in
{
  echo '#!/usr/bin/env bash'
  printf '# Installed by self-context on %s\n' "$(date)"
  printf '# Source: %s\n' "${INSTALL_DIR}/adapters/claude-code/statusline-ctx-writer.sh"
  echo ""
  printf 'export SELFCTX_CORE_DIR="%s"\n' "$CORE_ABS"
  printf 'export SELFCTX_CTX_STATE_DIR="%s"\n' "$CTX_STATE_DIR"
  if [ "$SAVE_EXISTING" = true ]; then
    # M-4: use single-quoted heredoc approach to avoid escaping issues with
    # arbitrary command strings (paths with spaces, args, env prefixes, etc.)
    # We bake the value in as a bash variable using printf %q for safe quoting.
    printf "export SELFCTX_STATUSLINE_CMD=%s\n" "$(printf '%q' "$existing_statusline")"
  fi
  echo ""
  # Inline the core writer logic (skip the shebang of the source file)
  tail -n +2 "${INSTALL_DIR}/adapters/claude-code/statusline-ctx-writer.sh"
} > "$WRAPPER_DEST"
chmod +x "$WRAPPER_DEST"
ok "Installed statusline wrapper → ${WRAPPER_DEST}"

# ─── Merge settings.json (non-destructive, idempotent) ───────────────────────
INJECT_CTX_PATH="${HOOK_DEST}/inject-ctx.sh"
INJECT_CTX_POSTTOOL_PATH="${HOOK_DEST}/inject-ctx-posttool.sh"
WRAPPER_PATH="$WRAPPER_DEST"

TMP=$(mktemp)

# Step 1: Update statusLine
jq --arg cmd "$WRAPPER_PATH" '
  .statusLine = {"type": "command", "command": $cmd}
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

# Step 2: Add UserPromptSubmit hook (idempotent)
jq --arg cmd "$INJECT_CTX_PATH" '
  if ((.hooks.UserPromptSubmit // []) | map(.hooks[]?.command // "") | any(. == $cmd)) then
    .
  else
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{"hooks": [{"type": "command", "command": $cmd}]}])
  end
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

# Step 3: Add PostToolUse hook for Agent matcher (idempotent)
jq --arg cmd "$INJECT_CTX_POSTTOOL_PATH" '
  if ((.hooks.PostToolUse // []) | map(select(.matcher == "Agent") | .hooks[]?.command // "") | any(. == $cmd)) then
    .
  else
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{"matcher": "Agent", "hooks": [{"type": "command", "command": $cmd}]}])
  end
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

# Step 4: Add PostToolUse hook for Task matcher (idempotent)
jq --arg cmd "$INJECT_CTX_POSTTOOL_PATH" '
  if ((.hooks.PostToolUse // []) | map(select(.matcher == "Task") | .hooks[]?.command // "") | any(. == $cmd)) then
    .
  else
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{"matcher": "Task", "hooks": [{"type": "command", "command": $cmd}]}])
  end
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

ok "settings.json updated (non-destructive merge)"

# ─── Post-install smoke: verify hook emits additionalContext JSON ─────────────
# Write a test ctx value, run the installed hook, confirm valid JSON is returned.
# This catches C-1-class failures (hook can't resolve core/emit-injection.sh).
SMOKE_SID="selfctx-smoke-$$"
SMOKE_FILE="${CTX_STATE_DIR}/${SMOKE_SID}"
printf 'ctx:99%%' > "$SMOKE_FILE"
smoke_out=$(printf '{"session_id":"%s"}' "$SMOKE_SID" | \
  SELFCTX_CTX_STATE_DIR="$CTX_STATE_DIR" bash "${HOOK_DEST}/inject-ctx.sh" 2>/dev/null || true)
rm -f "$SMOKE_FILE"

if printf '%s' "$smoke_out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "Smoke check: hook emits valid additionalContext JSON"
else
  fail "Smoke check FAILED: hook did not return additionalContext JSON"
  info "  Output: ${smoke_out:-<empty>}"
  info "  Run 'bash doctor.sh' for diagnostics."
  echo ""
  warn "Installation files were copied, but the smoke check failed."
  warn "Claude Code hooks may not work correctly."
  warn "Fix the issue above and re-run install.sh, or run 'bash doctor.sh'."
  echo ""
  exit 1
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "self-context installed successfully!"
info "Backup: ${BACKUP}"
info ""
info "Next step: restart Claude Code to activate."
info "Then run: bash doctor.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
