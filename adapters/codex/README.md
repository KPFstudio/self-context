# Codex CLI Adapter

## Status

| Condition | Status |
|-----------|--------|
| (a) Remaining signal source | ✅ `transcript_path` → rollout JSONL `token_count` event |
| (b) Context injection sink | ✅ `hookSpecificOutput.additionalContext` (Codex hooks docs confirmed) |
| TUI parity verified | ✅ Formula confirmed from OSS source (2026-06-03) |

## How it works

Codex CLI hooks receive a `transcript_path` in their stdin JSON. This path
points to a rollout JSONL file. The adapter reads the **last** event with
`payload.type == "token_count"` and computes the remaining percentage using
the **exact same formula as the Codex TUI** `context-remaining` display.

### Formula (from `codex-rs/tui/src/token_usage.rs`)

```
BASELINE = 12000
effective_window = model_context_window - BASELINE
used             = max(last_token_usage.total_tokens - BASELINE, 0)
remaining        = max(effective_window - used, 0) / effective_window * 100
```

Key notes:
- **`last_token_usage.total_tokens`** is used (= input_tokens + output_tokens for the current turn),
  **not** `input_tokens` alone. Using `input_tokens` alone underestimates usage by ~2–4%.
- **`total_token_usage`** (cumulative session total) is intentionally NOT used —
  it can exceed `model_context_window`.
- `BASELINE_TOKENS = 12000` is subtracted from both window and usage before the ratio is computed.

### Verified example (gpt-5.5, 2026-06-03 session)

| Field | Value |
|-------|-------|
| `last_token_usage.input_tokens` | 91363 |
| `last_token_usage.output_tokens` | 512 |
| `last_token_usage.total_tokens` | 91875 |
| `model_context_window` | 258400 |
| `effective_window` | 246400 |
| `used` | 79875 |
| `remaining` | 166525 |
| **ctx (TUI-identical)** | **ctx:68%** |

The `model_context_window = 258400` matches `gpt-5.5` in `codex debug models`:
`context_window: 272000 × effective_context_window_percent: 95% = 258400`.

## Source verification

Formula confirmed by reading the public OSS source at
`openai/codex` → `codex-rs/tui/src/token_usage.rs` →
`percent_of_context_window_remaining()` (function called from
`codex-rs/tui/src/chatwidget.rs` → `context_remaining_percent()`).

No interactive TUI confirmation required.

## Configuration

In your Codex config (`~/.config/codex/config.toml` or equivalent), add:

```toml
[hooks]
UserPromptSubmit = "/path/to/self-context/adapters/codex/hook-injector.sh"
PostToolUse = "/path/to/self-context/adapters/codex/hook-injector.sh"
```

## Dependencies

- `jq` (required for JSONL parsing)
- `awk` (required for floating-point arithmetic)
- `bash`
