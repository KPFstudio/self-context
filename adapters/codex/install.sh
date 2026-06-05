#!/usr/bin/env bash
# adapters/codex/install.sh — Install self-context into Codex CLI / Desktop config
#
# Usage:
#   bash adapters/codex/install.sh [--yes] [--codex-home PATH]
#
# This appends Codex hook entries to ~/.codex/config.toml idempotently.
# Codex requires hook trust on first launch after config changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTO_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) AUTO_YES=true; shift ;;
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; }
info() { printf "        %s\n" "$*"; }

CONFIG="${CODEX_HOME}/config.toml"
HOOK="${SCRIPT_DIR}/hook-injector.sh"

echo ""
echo "self-context Codex installer"
echo "════════════════════════════"
echo ""

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not found. Install with: brew install jq"
  exit 1
fi
ok "jq found: $(jq --version)"

if ! command -v awk >/dev/null 2>&1; then
  fail "awk is required but not found."
  exit 1
fi
ok "awk found"

if command -v codex >/dev/null 2>&1; then
  ok "codex found: $(codex --version 2>/dev/null | head -1 || echo 'version unknown')"
else
  warn "codex CLI not found in PATH. Install Codex before using this adapter."
fi

if [ ! -f "$HOOK" ]; then
  fail "Codex hook not found: ${HOOK}"
  exit 1
fi
chmod +x "$HOOK"
ok "Hook script executable: ${HOOK}"

mkdir -p "$CODEX_HOME"
if [ ! -f "$CONFIG" ]; then
  warn "config.toml not found at ${CONFIG}; creating it."
  : > "$CONFIG"
fi
ok "Codex config: ${CONFIG}"

echo ""
echo "Will add these Codex hooks:"
info "UserPromptSubmit → bash ${HOOK}"
info "PostToolUse      → bash ${HOOK}"
echo ""
warn "After installing, restart Codex and trust the hook when Codex asks."
warn "Without hook trust, Codex will load the config but will not run this hook."
echo ""

if [ "$AUTO_YES" = false ]; then
  printf "Proceed? [y/N] "
  read -r confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP="${CONFIG}.bak-selfctx-codex-${TIMESTAMP}"
cp "$CONFIG" "$BACKUP"
ok "Backed up config.toml → ${BACKUP}"

hook_cmd="bash ${HOOK}"

if grep -Fq "$hook_cmd" "$CONFIG"; then
  ok "Codex hook already present (idempotent; no duplicate added)"
else
  {
    printf '\n'
    printf '# self-context Codex adapter (experimental)\n'
    printf '[[UserPromptSubmit]]\n'
    printf '\n'
    printf '[[UserPromptSubmit.hooks]]\n'
    printf 'type = "command"\n'
    printf 'command = "%s"\n' "$hook_cmd"
    printf 'timeout = 5\n'
    printf 'statusMessage = "self-context"\n'
    printf '\n'
    printf '[[PostToolUse]]\n'
    printf '\n'
    printf '[[PostToolUse.hooks]]\n'
    printf 'type = "command"\n'
    printf 'command = "%s"\n' "$hook_cmd"
    printf 'timeout = 5\n'
    printf 'statusMessage = "self-context"\n'
  } >> "$CONFIG"
  ok "Added Codex hook blocks to config.toml"
fi

if command -v codex >/dev/null 2>&1; then
  if codex --strict-config --version >/dev/null 2>&1; then
    ok "Codex config parses with --strict-config"
  else
    fail "Codex config did not parse with --strict-config"
    info "Restore with: cp ${BACKUP} ${CONFIG}"
    exit 1
  fi
else
  warn "Skipped Codex config parse check because codex is not in PATH"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "self-context Codex adapter installed."
info "Next: restart Codex CLI / Desktop and trust the hook when prompted."
info "Then run: bash adapters/codex/doctor.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
