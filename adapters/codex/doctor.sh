#!/usr/bin/env bash
# adapters/codex/doctor.sh — Health check for Codex self-context adapter

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

while [ $# -gt 0 ]; do
  case "$1" in
    --codex-home)
      if [ -n "${2:-}" ]; then
        CODEX_HOME="$2"; shift 2
      else
        echo "Error: --codex-home requires a path" >&2; exit 1
      fi ;;
    --codex-home=*) CODEX_HOME="${1#--codex-home=}"; shift ;;
    *) shift ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "  ${GREEN}[OK]${NC}   %s\n" "$*"; }
warn() { printf "  ${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$*"; }
info_() { printf "  ${CYAN}[INFO]${NC} %s\n" "$*"; }

CONFIG="${CODEX_HOME}/config.toml"
CTX_STATE_DIR="${CODEX_HOME}/.ctx-state"
HOOK="${SCRIPT_DIR}/hook-injector.sh"
HOOK_CMD="bash ${HOOK}"

FAIL_COUNT=0
WARN_COUNT=0

echo ""
echo "self-context Codex doctor"
echo "═════════════════════════"
echo ""

if command -v jq >/dev/null 2>&1; then
  ok "jq found: $(jq --version)"
else
  fail "jq not found. Install with: brew install jq"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if command -v awk >/dev/null 2>&1; then
  ok "awk found"
else
  fail "awk not found"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if command -v codex >/dev/null 2>&1; then
  ok "codex found: $(codex --version 2>/dev/null | head -1 || echo 'version unknown')"
  if codex --strict-config --version >/dev/null 2>&1; then
    ok "Codex config parses with --strict-config"
  else
    fail "Codex config does not parse with --strict-config"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  warn "codex CLI not found in PATH"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ -f "$CONFIG" ]; then
  ok "config.toml exists: ${CONFIG}"
  if grep -Fq "$HOOK_CMD" "$CONFIG"; then
    ok "self-context hook registered in config.toml"
  else
    fail "self-context hook command not found in config.toml"
    info_ "Expected command: ${HOOK_CMD}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  fail "config.toml not found: ${CONFIG}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
  ok "Hook executable: ${HOOK}"
elif [ -f "$HOOK" ]; then
  warn "Hook exists but is not executable: ${HOOK}"
  WARN_COUNT=$((WARN_COUNT + 1))
else
  fail "Hook not found: ${HOOK}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

latest_transcript=$(find "${CODEX_HOME}/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | sort | tail -1 || true)
if [ -n "$latest_transcript" ]; then
  info_ "Latest rollout: ${latest_transcript}"
  smoke_out=$(printf '{"session_id":"selfctx-codex-doctor","transcript_path":"%s","hook_event_name":"UserPromptSubmit"}' "$latest_transcript" | \
    SELFCTX_CTX_STATE_DIR="$CTX_STATE_DIR" bash "$HOOK" 2>/dev/null || true)
  if printf '%s' "$smoke_out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    ok "Hook smoke: additionalContext JSON returned correctly"
    msg=$(printf '%s' "$smoke_out" | jq -r '.hookSpecificOutput.additionalContext')
    info_ "${msg}"
  else
    warn "Hook smoke did not emit additionalContext from latest rollout"
    warn "This is normal before the first token_count event exists."
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
else
  warn "No Codex rollout JSONL found yet. Start a Codex session, then run doctor again."
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ -d "$CTX_STATE_DIR" ]; then
  file_count=$(ls "$CTX_STATE_DIR" 2>/dev/null | wc -l | tr -d ' ')
  ok "ctx-state directory: ${CTX_STATE_DIR} (${file_count} file(s))"
else
  warn "ctx-state directory not found yet: ${CTX_STATE_DIR}"
  warn "It is created after the hook runs once."
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  printf "  ${GREEN}Codex self-context adapter is healthy.${NC}\n"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  printf "  ${YELLOW}Codex self-context adapter has %d warning(s). See above.${NC}\n" "$WARN_COUNT"
else
  printf "  ${RED}Codex self-context adapter has %d failure(s) and %d warning(s).${NC}\n" "$FAIL_COUNT" "$WARN_COUNT"
fi
echo ""
