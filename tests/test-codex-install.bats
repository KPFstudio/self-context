#!/usr/bin/env bats
# tests/test-codex-install.bats
# Tests for adapters/codex/install.sh and uninstall.sh

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  INSTALL="${REPO_ROOT}/adapters/codex/install.sh"
  UNINSTALL="${REPO_ROOT}/adapters/codex/uninstall.sh"
  HOOK="${REPO_ROOT}/adapters/codex/hook-injector.sh"

  FAKE_CODEX="$(mktemp -d)"
  mkdir -p "$FAKE_CODEX"
  cat > "${FAKE_CODEX}/config.toml" <<'EOF'
model = "gpt-5.5"

[projects."/tmp/example"]
trust_level = "trusted"
EOF
}

teardown() {
  rm -rf "$FAKE_CODEX"
}

run_install() {
  bash "$INSTALL" --yes --codex-home "$FAKE_CODEX"
}

run_uninstall() {
  bash "$UNINSTALL" --yes --codex-home "$FAKE_CODEX"
}

@test "codex-install: adds UserPromptSubmit and PostToolUse hook blocks" {
  run_install
  count=$(grep -F "command = \"bash ${HOOK}\"" "${FAKE_CODEX}/config.toml" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
  grep -Fq '[[UserPromptSubmit]]' "${FAKE_CODEX}/config.toml"
  grep -Fq '[[PostToolUse]]' "${FAKE_CODEX}/config.toml"
}

@test "codex-install: idempotent (2 installs = 2 command lines total)" {
  run_install
  run_install
  count=$(grep -F "command = \"bash ${HOOK}\"" "${FAKE_CODEX}/config.toml" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "codex-install: preserves existing config content" {
  run_install
  grep -Fq 'model = "gpt-5.5"' "${FAKE_CODEX}/config.toml"
  grep -Fq '[projects."/tmp/example"]' "${FAKE_CODEX}/config.toml"
  grep -Fq 'trust_level = "trusted"' "${FAKE_CODEX}/config.toml"
}

@test "codex-install: creates timestamp backup" {
  run_install
  backup_count=$(ls "${FAKE_CODEX}/config.toml.bak-selfctx-codex-"* 2>/dev/null | wc -l | tr -d ' ')
  [ "$backup_count" -ge 1 ]
}

@test "codex-uninstall: removes self-context hook blocks" {
  run_install
  run_uninstall
  count=$(grep -F "command = \"bash ${HOOK}\"" "${FAKE_CODEX}/config.toml" | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

@test "codex-uninstall: preserves unrelated config content" {
  run_install
  run_uninstall
  grep -Fq 'model = "gpt-5.5"' "${FAKE_CODEX}/config.toml"
  grep -Fq '[projects."/tmp/example"]' "${FAKE_CODEX}/config.toml"
}
