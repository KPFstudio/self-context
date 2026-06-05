#!/usr/bin/env bats
# tests/test-codex-install.bats
# Tests for adapters/codex/install.sh and uninstall.sh

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  INSTALL="${REPO_ROOT}/adapters/codex/install.sh"
  UNINSTALL="${REPO_ROOT}/adapters/codex/uninstall.sh"
  DOCTOR="${REPO_ROOT}/adapters/codex/doctor.sh"
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

@test "codex-doctor: first run creates ctx-state before reporting directory status" {
  run_install
  rm -rf "${FAKE_CODEX}/.ctx-state"

  transcript_dir="${FAKE_CODEX}/sessions/2026/06/05"
  mkdir -p "$transcript_dir"
  transcript="${transcript_dir}/rollout-2026-06-05T00-00-00-test.jsonl"
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50000,"cached_input_tokens":0,"output_tokens":512,"reasoning_output_tokens":0,"total_tokens":50512},"model_context_window":200000}}}\n' > "$transcript"

  run bash "$DOCTOR" --codex-home "$FAKE_CODEX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hook smoke: additionalContext JSON returned correctly"* ]]
  [[ "$output" == *"ctx-state directory:"* ]]
  [[ "$output" != *"ctx-state directory not found yet"* ]]
}

@test "codex-install: supports older codex without --strict-config" {
  fake_bin="$(mktemp -d)"
  cat > "${fake_bin}/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--strict-config" ]; then
  echo "error: unknown argument '--strict-config'" >&2
  exit 2
fi
if [ "${1:-}" = "--version" ] || [ "$#" -eq 0 ]; then
  if [ -n "${CODEX_HOME:-}" ] && grep -q 'invalid toml' "${CODEX_HOME}/config.toml" 2>/dev/null; then
    echo "config parse error" >&2
    exit 1
  fi
  echo "codex-cli 0.128.0"
  exit 0
fi
exit 0
EOF
  chmod +x "${fake_bin}/codex"

  PATH="${fake_bin}:$PATH" run bash "$INSTALL" --yes --codex-home "$FAKE_CODEX"
  rm -rf "$fake_bin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex config parses"* ]]
  [[ "$output" != *"strict-config"* ]]
}

@test "codex-doctor: supports older codex without --strict-config" {
  run_install
  fake_bin="$(mktemp -d)"
  cat > "${fake_bin}/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--strict-config" ]; then
  echo "error: unknown argument '--strict-config'" >&2
  exit 2
fi
if [ "${1:-}" = "--version" ] || [ "$#" -eq 0 ]; then
  echo "codex-cli 0.128.0"
  exit 0
fi
exit 0
EOF
  chmod +x "${fake_bin}/codex"

  PATH="${fake_bin}:$PATH" run bash "$DOCTOR" --codex-home "$FAKE_CODEX"
  rm -rf "$fake_bin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex config parses"* ]]
  [[ "$output" != *"strict-config"* ]]
}

@test "codex-uninstall: removes self-context comment with hook blocks" {
  run_install
  run_uninstall
  ! grep -Fq '# self-context Codex adapter (experimental)' "${FAKE_CODEX}/config.toml"
}
