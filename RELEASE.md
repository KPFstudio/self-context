# Release — self-context (selfctx)

**self-context gives an agentic coding session self-awareness of its own remaining
context budget, so it can decide on its own when to checkpoint, hand off, or stop.**

> Published as the standalone repository
> [`github.com/KPFstudio/self-context`](https://github.com/KPFstudio/self-context).

---

## What it is

`selfctx` captures the `ctx:NN%` remaining-context value that Claude Code exposes via
`statusLine`, persists it per session, and re-injects it into every turn (and after every
sub-agent) through hook `additionalContext`. The model then sees, at the top of each turn:

```
[Context self-awareness] Current statusline value: ctx:72% (remaining).
This is REMAINING context (higher = more room left); do not invert it.
If remaining is low, consider starting a new session / doing a handoff.
```

It is a **capture → persist → inject** pipeline.

## What it is NOT

- **Not a token counter.** Claude Code computes `context_window.remaining_percentage`
  internally; selfctx only reads, stores, and re-injects that value. No token math, no
  model-specific window calculation, no inference about "what is in context".
- **Not a multi-agent tool (in v1.0.0).** `statusLine` and `hooks` are Claude Code-specific
  mechanisms. selfctx does **not** work with Cursor, OpenCode, Gemini CLI, etc.
- **Codex / OpenCode support is experimental / under investigation**, not a v1.0.0 feature.
  A Codex CLI adapter is included with feasibility confirmed but is **not** part of the
  stable surface — see *Roadmap* below.

## Requirements

| Requirement | Notes |
|-------------|-------|
| **Claude Code** | recent version with `statusLine` and `hooks` (`UserPromptSubmit`, `PostToolUse`) support |
| **`bash`** | hook and installer scripts are bash |
| **`jq`** | used for non-destructive `settings.json` merges (`brew install jq`) |

The experimental Codex adapter additionally relies on the Codex rollout JSONL transcript;
it has no extra runtime dependency beyond `bash` + `jq`.

## Install / Uninstall / Doctor

```bash
git clone https://github.com/KPFstudio/self-context
cd self-context
bash install.sh          # interactive; prompts before writing
# or, non-interactive:
bash install.sh --yes
```

Then restart Claude Code to activate, and verify:

```bash
bash doctor.sh
```

To remove:

```bash
bash uninstall.sh        # add --yes to skip the prompt
```

Useful flags (all three scripts):

| Flag | Effect |
|------|--------|
| `--yes` | skip confirmation prompts (install / uninstall) |
| `--claude-home PATH` | target a directory other than `~/.claude` (used by tests and fresh-machine trials) |

If you already run a `statusLine` command, set `SELFCTX_STATUSLINE_CMD` before installing so
the wrapper delegates to it and still captures `ctx:NN%`. On uninstall, the original
`statusLine` and any pre-existing hooks are restored. Backups
(`settings.json.bak-selfctx-*`) are created on every install/uninstall and are never
deleted automatically.

### Behaviour guarantees (verified)

- **Non-destructive merge** — existing hooks (e.g. `claude-mem`) and `statusLine` are preserved.
- **Idempotent install** — running `install.sh` twice produces a single set of entries.
- **Clean uninstall** — only selfctx entries are removed; original `statusLine` is restored.
- **Silent when inactive** — with no ctx-state file, hooks exit 0 with no output.
- **Install smoke check** — install fails loudly if the hook cannot emit valid
  `additionalContext` JSON (guards against a mis-wired `core/` path).

## v1.0.0 scope

| Component | Status |
|-----------|--------|
| `adapters/claude-code/statusline-ctx-writer.sh` — capture `ctx:NN%` (delegate or minimal) | stable |
| `adapters/claude-code/hook-userpromptsubmit.sh` — inject at turn start | stable |
| `adapters/claude-code/hook-posttooluse.sh` — re-inject after sub-agents (`Agent`/`Task`) | stable |
| `core/emit-injection.sh` — shared injection JSON builder | stable |
| `install.sh` / `uninstall.sh` / `doctor.sh` / `bin/selfctx` | stable |
| `adapters/codex/hook-injector.sh` — Codex CLI adapter | **experimental** |

v1.0.0 ships the Claude Code adapter: per-turn ctx self-awareness via a statusLine writer
plus `UserPromptSubmit` / `PostToolUse` injection hooks, with safe install/uninstall/doctor
tooling.

## Known limitations / Roadmap

- **Claude Code only.** Other agents are not supported in v1.0.0.
- **Codex CLI adapter — experimental.** Feasibility is confirmed and TUI-parity of the
  remaining-% formula was verified from Codex OSS source
  (`codex-rs/tui/src/token_usage.rs`, 2026-06-03). It is **not** considered stable until
  real-world usage validation is complete. See `adapters/codex/README.md`.
- **OpenCode — under investigation.** Needs confirmation of a per-turn hook plus a token /
  context-window exposure API before an adapter can be built.

## Versioning

self-context follows [Semantic Versioning](https://semver.org/). Breaking changes to the
install layout, hook contract, or `settings.json` shape bump the MAJOR version; new
backward-compatible adapters or flags bump MINOR; fixes bump PATCH. The experimental Codex
adapter is exempt from SemVer guarantees until promoted to stable.

## Changelog

### v1.0.1

- **Fix (Critical): Codex CLI config example.** The previous `[hooks]` table form is rejected by current Codex CLI (`config could not be loaded`) and could break a user's `~/.codex/config.toml`. Replaced with the `[[UserPromptSubmit]]` / `[[UserPromptSubmit.hooks]]` array-of-tables form; path corrected to `~/.codex/config.toml`. Surfaced by real-usage testing in Codex Desktop.
- Added Codex hook-trust guidance and a config-recovery section to `adapters/codex/README.md`.
- Codex adapter state dir now defaults to `~/.codex/.ctx-state` (Claude Code adapter keeps `~/.claude/.ctx-state`).
- Codex `PostToolUse` injection wording no longer says "Sub-agent completed" (Codex fires PostToolUse after any tool); Claude Code wording unchanged.

### v1.0.0

- **Claude Code adapter (stable):** capture `ctx:NN%` remaining-context via `statusLine`,
  persist per session, and inject into every turn (`UserPromptSubmit`) and after every
  sub-agent (`PostToolUse`, matchers `Agent` and `Task`) — enabling autonomous
  checkpoint / handoff / stop decisions.
- **Tooling:** non-destructive idempotent `install.sh` (with `--yes` / `--claude-home`,
  timestamped backups, post-install smoke check), `uninstall.sh` that restores the original
  `statusLine` and preserves other hooks, and `doctor.sh` health check.
- **`bin/selfctx`** convenience entrypoint.
- **Experimental Codex CLI adapter** (`adapters/codex/`): remaining-% computed with the same
  formula as the Codex TUI; feasibility and TUI parity confirmed from OSS source.
- **Docs:** English `README.md` and Japanese `README.ja.md` with "Claude Code only",
  "What it is NOT", and Codex-experimental sections; MIT `LICENSE`.
- **Tests:** 57 `bats` tests covering injection, hooks, install/uninstall merge semantics,
  the Codex adapter formula, and C-1 / M-1 / M-4 regressions — all passing.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 KPF Studio.
