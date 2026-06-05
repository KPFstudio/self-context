#!/usr/bin/env bash
# adapters/codex/uninstall.sh — Remove self-context Codex hook blocks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
info() { printf "        %s\n" "$*"; }

CONFIG="${CODEX_HOME}/config.toml"
HOOK="${SCRIPT_DIR}/hook-injector.sh"
HOOK_CMD="bash ${HOOK}"

echo ""
echo "self-context Codex uninstaller"
echo "══════════════════════════════"
echo ""

if [ ! -f "$CONFIG" ]; then
  warn "config.toml not found at ${CONFIG}. Nothing to remove."
  exit 0
fi

echo "Will remove Codex hook command:"
info "${HOOK_CMD}"
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
BACKUP="${CONFIG}.bak-selfctx-codex-uninstall-${TIMESTAMP}"
cp "$CONFIG" "$BACKUP"
ok "Backed up config.toml → ${BACKUP}"

tmp=$(mktemp)
awk -v hook="$HOOK_CMD" '
  BEGIN { block = ""; inblock = 0; keep = 1 }
  /^\[\[(UserPromptSubmit|PostToolUse)\]\]$/ {
    if (inblock && keep) printf "%s", block
    block = $0 "\n"; inblock = 1; keep = 1; next
  }
  /^\[\[[^].]+\]\]$/ {
    if (inblock && keep) printf "%s", block
    block = ""; inblock = 0; keep = 1
    print; next
  }
  inblock {
    block = block $0 "\n"
    if (index($0, "command = \"" hook "\"") > 0) keep = 0
    next
  }
  { print }
  END {
    if (inblock && keep) printf "%s", block
  }
' "$CONFIG" > "$tmp"
tmp2=$(mktemp)
grep -v '^# self-context Codex adapter (experimental)$' "$tmp" > "$tmp2"
mv "$tmp2" "$tmp"
mv "$tmp" "$CONFIG"

ok "Removed matching self-context Codex hook blocks"
info "Restart Codex CLI / Desktop to apply."
echo ""
