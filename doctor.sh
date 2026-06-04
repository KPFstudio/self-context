#!/usr/bin/env bash
# doctor.sh — Health check for self-context installation
#
# Usage:
#   bash doctor.sh [--claude-home PATH]
#
# Checks:
#   - jq available
#   - settings.json exists and is valid JSON
#   - statusLine wired to ctx-capture-wrapper.sh
#   - UserPromptSubmit hook registered
#   - PostToolUse hook registered (Agent and/or Task)
#   - Script files exist and are executable
#   - ctx-state directory exists
#   - Latest ctx value (if any)
#   - Backup files listing

set -uo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

while [ $# -gt 0 ]; do
  case "$1" in
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "  ${GREEN}[OK]${NC}   %s\n" "$*"; }
warn() { printf "  ${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$*"; }
info_() { printf "  ${CYAN}[INFO]${NC} %s\n" "$*"; }

SETTINGS="${CLAUDE_HOME}/settings.json"
HOOK_DEST="${CLAUDE_HOME}/hooks"
STATUSLINE_DEST="${CLAUDE_HOME}/statusline"
CTX_STATE_DIR="${CLAUDE_HOME}/.ctx-state"

INJECT_CTX="${HOOK_DEST}/inject-ctx.sh"
INJECT_CTX_POSTTOOL="${HOOK_DEST}/inject-ctx-posttool.sh"
WRAPPER="${STATUSLINE_DEST}/ctx-capture-wrapper.sh"

echo ""
echo "self-context doctor"
echo "═══════════════════"
echo ""

FAIL_COUNT=0
WARN_COUNT=0

# ─── jq ───────────────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  ok "jq found: $(jq --version)"
else
  fail "jq not found. Install with: brew install jq"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─── Claude Code ──────────────────────────────────────────────────────────────
if command -v claude >/dev/null 2>&1; then
  ok "claude found: $(claude --version 2>/dev/null | head -1 || echo 'version unknown')"
else
  warn "claude CLI not found in PATH"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─── settings.json ────────────────────────────────────────────────────────────
if [ -f "$SETTINGS" ]; then
  if command -v jq >/dev/null 2>&1 && jq empty < "$SETTINGS" >/dev/null 2>&1; then
    ok "settings.json exists and is valid JSON: ${SETTINGS}"
  else
    fail "settings.json exists but is not valid JSON: ${SETTINGS}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  fail "settings.json not found: ${SETTINGS}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─── statusLine ───────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  statusline_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
  if printf '%s' "$statusline_cmd" | grep -q 'ctx-capture-wrapper\|selfctx\|self-context'; then
    ok "statusLine → ${statusline_cmd}"
  elif [ -n "$statusline_cmd" ]; then
    fail "statusLine is set but does not point to selfctx wrapper"
    info_ "Current: ${statusline_cmd}"
    info_ "Expected: ${WRAPPER}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    fail "statusLine is not configured"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ─── UserPromptSubmit hook ─────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  ups_cmd=$(jq -r '(.hooks.UserPromptSubmit // []) | map(.hooks[]?.command // "") | .[]' \
    "$SETTINGS" 2>/dev/null | grep 'inject-ctx' | head -1 || true)
  if [ -n "$ups_cmd" ]; then
    ok "UserPromptSubmit hook: ${ups_cmd}"
  else
    fail "UserPromptSubmit hook not found in settings.json"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ─── PostToolUse hook ──────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  ptu_cmd=$(jq -r '(.hooks.PostToolUse // []) | map(.hooks[]?.command // "") | .[]' \
    "$SETTINGS" 2>/dev/null | grep 'inject-ctx-posttool' | head -1 || true)
  if [ -n "$ptu_cmd" ]; then
    ptu_matchers=$(jq -r '(.hooks.PostToolUse // []) | map(select(.hooks[]?.command? // "" | test("inject-ctx-posttool"))) | map(.matcher // "none") | join(", ")' \
      "$SETTINGS" 2>/dev/null || true)
    ok "PostToolUse hook (matchers: ${ptu_matchers}): ${ptu_cmd}"
  else
    fail "PostToolUse hook not found in settings.json"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ─── Script files ─────────────────────────────────────────────────────────────
for f in "$INJECT_CTX" "$INJECT_CTX_POSTTOOL" "$WRAPPER"; do
  if [ -f "$f" ] && [ -x "$f" ]; then
    ok "Executable: ${f}"
  elif [ -f "$f" ]; then
    warn "Exists but not executable: ${f}  (run: chmod +x ${f})"
    WARN_COUNT=$((WARN_COUNT + 1))
  else
    fail "Not found: ${f}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

# ─── ctx-state directory ──────────────────────────────────────────────────────
if [ -d "$CTX_STATE_DIR" ]; then
  file_count=$(ls "$CTX_STATE_DIR" 2>/dev/null | wc -l | tr -d ' ')
  ok "ctx-state directory: ${CTX_STATE_DIR}  (${file_count} session file(s))"
else
  warn "ctx-state directory not found: ${CTX_STATE_DIR}"
  warn "Will be created automatically on first use."
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─── Smoke: hook emits additionalContext JSON ─────────────────────────────────
# This detects C-1-class failures: hook installed but can't find emit-injection.sh,
# so the hook exits non-zero or returns no output even when ctx-state is populated.
if [ -f "$INJECT_CTX" ] && [ -x "$INJECT_CTX" ]; then
  SMOKE_SID="selfctx-doctor-smoke-$$"
  SMOKE_FILE="${CTX_STATE_DIR}/${SMOKE_SID}"
  mkdir -p "$CTX_STATE_DIR"
  printf 'ctx:99%%' > "$SMOKE_FILE"
  smoke_out=$(printf '{"session_id":"%s"}' "$SMOKE_SID" | \
    SELFCTX_CTX_STATE_DIR="$CTX_STATE_DIR" bash "$INJECT_CTX" 2>/dev/null || true)
  rm -f "$SMOKE_FILE"
  if printf '%s' "$smoke_out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    ok "Hook smoke: additionalContext JSON returned correctly"
  else
    fail "Hook smoke FAILED: inject-ctx.sh returned no valid additionalContext"
    info_ "  Expected: {\"hookSpecificOutput\":{\"additionalContext\":\"...\"}}"
    info_ "  Got: ${smoke_out:-<empty>}"
    info_ "  Likely cause: SELFCTX_CORE_DIR not wired (re-run install.sh to fix)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ─── Latest ctx value ─────────────────────────────────────────────────────────
if [ -d "$CTX_STATE_DIR" ]; then
  latest_file=$(ls -t "$CTX_STATE_DIR" 2>/dev/null | head -1 || true)
  if [ -n "$latest_file" ]; then
    latest_ctx=$(cat "${CTX_STATE_DIR}/${latest_file}" 2>/dev/null || true)
    if [ -n "$latest_ctx" ]; then
      info_ "Latest ctx value: ${latest_ctx}  (session: ${latest_file})"
    else
      info_ "Latest ctx-state file is empty (no API response yet?)"
    fi
  fi
fi

# ─── Backups ──────────────────────────────────────────────────────────────────
BACKUPS=$(ls "${CLAUDE_HOME}/settings.json.bak-selfctx-"* 2>/dev/null | sort -r || true)
if [ -n "$BACKUPS" ]; then
  backup_count=$(echo "$BACKUPS" | wc -l | tr -d ' ')
  info_ "${backup_count} backup(s) found (not deleted):"
  while IFS= read -r b; do
    info_ "  ${b}"
  done <<< "$BACKUPS"
  if [ "$backup_count" -gt 3 ]; then
    warn "Consider cleaning up old backups: rm ${CLAUDE_HOME}/settings.json.bak-selfctx-*"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  printf "  ${GREEN}selfctx is healthy.${NC} Restart Claude Code if you haven't already.\n"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  printf "  ${YELLOW}selfctx has %d warning(s). See above.${NC}\n" "$WARN_COUNT"
else
  printf "  ${RED}selfctx has %d failure(s) and %d warning(s).${NC}\n" "$FAIL_COUNT" "$WARN_COUNT"
  echo ""
  echo "  To fix: bash install.sh"
fi
echo ""
