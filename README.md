# self-context (selfctx)

> Self-awareness of remaining context for agentic coding sessions

> ⚠️ **Stable v1 support targets Claude Code.** `statusLine` is Claude Code-specific.
> Codex CLI is supported only through the included **experimental** adapter (see below).
> Cursor, OpenCode, Gemini CLI, and other agents are not supported.

---

## Why this exists

Claude Code does not reliably know how much of its context window remains. The `statusLine`
shows a percentage to **you, the human** — but that number is never placed into the model's
own prompt. The model is effectively flying blind about its own remaining budget.

This matters because the highest-stakes decisions in a long session depend on exactly that number:

- **When to compact** (summarize and drop history)
- **When to hand off** to a fresh session
- **When to stop** before quality degrades

Without an accurate remaining-context signal, the model guesses — and guesses wrong. It compacts
too early (throwing away context it still needs) or too late (after quality has already started to
slip), and it hands off at the wrong moment. The result is lost work and degraded output exactly
when the session matters most.

self-context closes this gap. It feeds the exact remaining-% that Claude Code already computes
back into the model on every turn. The model now **knows** how much room it has left, and makes
checkpoint / handoff / stop decisions on accurate information instead of a guess.

## What it is

`selfctx` captures the `ctx:NN%` remaining context value that Claude Code exposes via
`statusLine`, persists it to a file, and injects it into every turn via `additionalContext`.

With self-context installed, Claude sees at the start of each turn (and after each
sub-agent completes):

```
[Context self-awareness] Current statusline value: ctx:72% (remaining).
This is REMAINING context (higher = more room left); do not invert it.
If remaining is low, consider starting a new session / doing a handoff.
```

This allows Claude to autonomously trigger checkpoint / handoff / stop decisions
without waiting for human intervention.

## What it is NOT

**selfctx does not calculate token counts itself.**

Token counting is done by Claude Code internally. Claude Code exposes the result as
`context_window.remaining_percentage` in the stdin JSON it passes to every `statusLine`
command. selfctx only reads that value, persists it to a file, and injects it into
`additionalContext` via hooks.

- No token counting logic
- No model-specific context window math
- No inference about what is "in context"

selfctx is a **capture → persist → inject** pipeline, not a measurement tool.

## How it works

```
Claude Code (internal)
  └── computes context_window.remaining_percentage
        │
        ▼  (calls statusLine command with stdin JSON each API turn)
adapters/claude-code/statusline-ctx-writer.sh
  ├── delegates to your existing statusLine command (if any)
  ├── extracts ctx:NN% from the output (or from stdin JSON directly)
  └── writes ctx:NN% to ~/.claude/.ctx-state/<session_id>
        │
        ▼  (UserPromptSubmit or PostToolUse hook fires)
adapters/claude-code/hook-userpromptsubmit.sh  (or hook-posttooluse.sh)
  ├── reads ~/.claude/.ctx-state/<session_id>
  └── outputs { hookSpecificOutput: { additionalContext: "ctx:NN% (remaining)..." } }
        │
        ▼
Claude sees ctx:NN% at turn start → can self-regulate session length
```

**Key design properties:**
- **Silent when inactive**: if no ctx-state file exists (first turn, uninstalled), hooks exit 0 with no output
- **Non-destructive**: existing hooks and statusLine commands are preserved
- **Idempotent install**: running `install.sh` twice doesn't duplicate entries

## Requirements

| Target | Requirements | Support level |
|--------|--------------|---------------|
| **Claude Code** | Recent version with `statusLine` and `hooks`; `bash`; `jq` | **Stable** |
| **Codex CLI / Codex Desktop** | Codex with hooks and rollout JSONL transcripts; `bash`; `jq`; `awk` | **Experimental** |

Codex support is real but not yet part of the stable surface. Use
`adapters/codex/install.sh` or `bin/selfctx install-codex` and approve Codex hook
trust when prompted.

> Standalone repository: <https://github.com/KPFstudio/self-context>
> Current release: `v1.0.5`.

## Install

### Claude Code (stable)

```bash
git clone https://github.com/KPFstudio/self-context
cd self-context
bash install.sh          # add --yes to skip the confirmation prompt
```

Restart Claude Code to activate. Then verify:

```bash
bash doctor.sh
```

### With an existing statusLine command

If you already have a `statusLine` command configured, set the environment variable
before installing (or export it in your shell profile):

```bash
export SELFCTX_STATUSLINE_CMD="/path/to/your/existing/statusline.sh"
bash install.sh
```

The wrapper will delegate to your existing command and additionally capture `ctx:NN%`.

### Codex CLI / Codex Desktop (experimental)

Codex support is included as an experimental adapter. It does not use Claude Code
`statusLine`; it reads Codex rollout JSONL via hook stdin and computes the same
remaining-% shown by the Codex TUI.

```bash
git clone https://github.com/KPFstudio/self-context
cd self-context
bash adapters/codex/install.sh
```

Then restart Codex CLI / Codex Desktop. Codex will ask you to review and trust the
new hook; approve it, or the adapter will be configured but will not run.

Verify after you have run at least one Codex turn:

```bash
bash adapters/codex/doctor.sh
```

If you use the convenience entrypoint:

```bash
bin/selfctx install-codex
bin/selfctx doctor-codex
```

## Uninstall

Claude Code:

```bash
bash uninstall.sh
```

This removes the installed hook scripts and cleans selfctx entries from `settings.json`.
Your original hooks and other settings are preserved. Backup files are listed but not deleted.

Codex:

```bash
bash adapters/codex/uninstall.sh
```

This removes only the matching self-context hook blocks from `~/.codex/config.toml`.
It creates a timestamped backup first.

## Doctor

Claude Code:

```bash
bash doctor.sh
```

Checks:
- `jq` available
- `settings.json` valid
- `statusLine` wired correctly
- Both hooks registered
- Script files exist and are executable
- Latest ctx value from most recent session

Codex:

```bash
bash adapters/codex/doctor.sh
```

Checks:
- `jq`, `awk`, and `codex` availability
- `~/.codex/config.toml` contains the self-context hook
- Codex config parses with the installed `codex` CLI
- Hook script exists and is executable
- Latest rollout JSONL can produce `additionalContext`

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SELFCTX_CTX_STATE_DIR` | `~/.claude/.ctx-state` | Directory for per-session ctx files |
| `SELFCTX_STATUSLINE_CMD` | (none) | Your existing statusLine command to delegate to |
| `SELFCTX_CORE_DIR` | `<install>/core` | Path to core/emit-injection.sh |

Codex adapter:

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_HOME` | `~/.codex` | Codex config and rollout directory |
| `SELFCTX_CTX_STATE_DIR` | `~/.codex/.ctx-state` | Directory for per-session ctx files |
| `SELFCTX_CORE_DIR` | `<install>/core` | Path to core/emit-injection.sh |

### PostToolUse matcher: Agent vs Task

Claude Code environments differ in the tool name used for sub-agents.
This repo's environment uses `Agent`; some versions use `Task`.
`install.sh` registers both matchers so the hook fires on either.
If you experience double-firing, remove the matcher you don't need from `settings.json`.

## Stable surface: Claude Code (v1)

`statusLine` and `hooks.UserPromptSubmit` / `hooks.PostToolUse` are mechanisms
specific to Claude Code. Other hosts need different adapters:

- Codex CLI: experimental adapter included below; it uses rollout JSONL instead of `statusLine`
- OpenCode (partial hooks support, per-turn injection unconfirmed as of 2026-06-02)
- Cursor, Windsurf, Gemini CLI, etc.

## Experimental: Codex CLI adapter

`adapters/codex/hook-injector.sh` is an **experimental** adapter for Codex CLI.

The installer writes the same hook configuration to `~/.codex/config.toml`, which is
the shared config location used by normal Codex CLI installations and current Codex
Desktop builds that use the same Codex home. If your Desktop build uses a different
Codex home, set `CODEX_HOME` or pass `--codex-home`.

It works by reading the `transcript_path` from hook stdin, parsing the rollout JSONL,
and computing the remaining percentage using the **same formula as the Codex TUI**
(`codex-rs/tui/src/token_usage.rs`):

```
BASELINE = 12000
effective_window = model_context_window - BASELINE
used             = max(last_token_usage.total_tokens - BASELINE, 0)
remaining        = max(effective_window - used, 0) / effective_window * 100
```

`last_token_usage.total_tokens` (= input + output tokens for the current turn) is used —
not `input_tokens` alone, which underestimates usage by ~2–4%.

**Status**: feasibility confirmed. TUI parity verified from OSS source (2026-06-03).

See `adapters/codex/README.md` for details.

## Value per host

| Host | Value type | What it enables |
|------|-----------|-----------------|
| **Claude Code** | enabling | Claude gains autonomous awareness of remaining budget per turn |
| **Codex CLI** (experimental) | automating | Same awareness, via transcript JSONL parsing |
| **OpenCode** | under investigation | Needs per-turn hook + token exposure API |

## License

MIT — see [LICENSE](LICENSE).

## Release notes & changelog

See [RELEASE.md](RELEASE.md).
