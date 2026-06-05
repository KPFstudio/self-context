# self-context (selfctx)

> エージェント型コーディングセッションにおける残コンテキスト量の自己認識

> ⚠️ **v1 の stable 対象は Claude Code です。** `statusLine` は Claude Code 固有の機構です。
> Codex CLI は同梱の **experimental** アダプターでのみ対応します（下記参照）。
> Cursor、OpenCode、Gemini CLI 等の他エージェントは未対応です。

---

## なぜ必要か

Claude Code は、自分のコンテキストウィンドウがあとどれだけ残っているかを正確には把握していません。
`statusLine` は残量パーセントを **人間（あなた）** には見せますが、その数値が **モデル自身のプロンプト**
に入ることはありません。モデルは自分の残り予算について、実質「目隠し」のまま動いています。

これが問題になるのは、長いセッションで最も重要な判断のいくつかが、まさにこの残量に依存するからです：

- **いつ圧縮（compaction）するか**（履歴を要約して落とす）
- **いつ別セッションへ引き継ぐ（handoff）か**
- **いつ止めるか**（品質が落ちる前に）

正確な残量シグナルがないと、モデルは当て推量で判断し、そして外します。早すぎる圧縮（まだ必要な文脈を失う）、
遅すぎる圧縮（劣化が始まってから）、間違ったタイミングでの引き継ぎ——セッションが一番大事な局面で、
作業の損失と出力品質の低下を招きます。

self-context はこのギャップを埋めます。Claude Code が既に計算している正確な残量％を、毎ターン
モデルに返します。モデルは「あと何割使えるか」を **正確に把握** した上で、圧縮 / 引き継ぎ / 停止を、
当て推量でなく事実に基づいて判断できるようになります。

## これは何か

`selfctx` は Claude Code の `statusLine` が提供する残コンテキスト量 `ctx:NN%`（remaining）を
ファイルに捕捉・永続化し、毎ターン `additionalContext` 経由でモデルの文脈に注入するツールです。

self-context をインストールすると、Claude は各ターンの冒頭（およびサブエージェント完了時）に以下を受け取ります：

```
[Context self-awareness] Current statusline value: ctx:72% (remaining).
This is REMAINING context (higher = more room left); do not invert it.
If remaining is low, consider starting a new session / doing a handoff.
```

これにより Claude は人間が介入しなくても、checkpoint / handoff / stop を自律的に判断できるようになります。

## これは何ではないか

**selfctx は自前でトークン計算をするツールではありません。**

トークン計算は Claude Code の内部処理が行います。Claude Code はその結果を
`context_window.remaining_percentage` として `statusLine` コマンドの stdin JSON に含めて渡します。
selfctx はその値を読み取り、ファイルに書き込み、hook 経由で `additionalContext` に注入するだけです。

- トークン計算ロジックなし
- モデル固有のコンテキストウィンドウ計算なし
- 「何がコンテキストに入っているか」の推定なし

selfctx は **捕捉 → 永続化 → 注入** のパイプラインであり、計測ツールではありません。

## 動作の仕組み

```
Claude Code（内部処理）
  └── context_window.remaining_percentage を計算
        │
        ▼  （各 API ターンで statusLine コマンドを stdin JSON 付きで呼び出す）
adapters/claude-code/statusline-ctx-writer.sh
  ├── 既存の statusLine コマンドに委譲（設定されている場合）
  ├── 出力から ctx:NN% を抽出（または stdin JSON から直接取得）
  └── ctx:NN% を ~/.claude/.ctx-state/<session_id> に書き込む
        │
        ▼  （UserPromptSubmit または PostToolUse hook が発火）
adapters/claude-code/hook-userpromptsubmit.sh  （または hook-posttooluse.sh）
  ├── ~/.claude/.ctx-state/<session_id> を読む
  └── { hookSpecificOutput: { additionalContext: "ctx:NN% (remaining)..." } } を出力
        │
        ▼
Claude がターン冒頭で ctx:NN% を認識 → セッション長を自己調整できる
```

**設計上の重要な特性：**
- **未インストール時は無音**: ctx-state ファイルが存在しない場合、hook は何も出力せず exit 0
- **非破壊**: 既存の hooks と statusLine コマンドを保持
- **冪等インストール**: `install.sh` を 2 回実行してもエントリが重複しない

## 動作要件

- Claude Code（`statusLine` と `hooks` をサポートする最近のバージョン）
- `bash`
- `jq`

> 単独リポジトリ: <https://github.com/KPFstudio/self-context>
> 現在のリリース: `v1.0.3`。

## インストール

### Claude Code（stable）

```bash
git clone https://github.com/KPFstudio/self-context
cd self-context
bash install.sh          # 確認プロンプトを省略するには --yes
```

インストール後、Claude Code を再起動して有効化します。次に動作確認：

```bash
bash doctor.sh
```

### 既存の statusLine コマンドがある場合

すでに `statusLine` コマンドが設定されている場合は、インストール前に環境変数を設定してください（またはシェルプロファイルに export してください）：

```bash
export SELFCTX_STATUSLINE_CMD="/path/to/your/existing/statusline.sh"
bash install.sh
```

ラッパーは既存のコマンドに委譲しつつ、`ctx:NN%` も捕捉します。

### Codex CLI / Codex Desktop（experimental）

Codex 対応は experimental アダプターとして同梱しています。Claude Code の
`statusLine` は使わず、Codex hook stdin の rollout JSONL を読み、Codex TUI と
同じ式で残量％を計算します。

```bash
git clone https://github.com/KPFstudio/self-context
cd self-context
bash adapters/codex/install.sh
```

インストール後、Codex CLI / Codex Desktop を再起動してください。Codex が hook
の review / trust を求めるので承認します。承認しない場合、設定は入っていても
hook は通常セッションで実行されません。

少なくとも 1 回 Codex のターンを実行した後で確認します：

```bash
bash adapters/codex/doctor.sh
```

便利エントリポイントを使う場合：

```bash
bin/selfctx install-codex
bin/selfctx doctor-codex
```

## アンインストール

Claude Code:

```bash
bash uninstall.sh
```

インストールしたファイルを削除し、`settings.json` から selfctx のエントリを除去します。
元の hooks やその他の設定は保持されます。バックアップファイルは表示されますが削除されません。

Codex:

```bash
bash adapters/codex/uninstall.sh
```

`~/.codex/config.toml` から self-context に一致する hook block のみを削除します。
削除前に timestamp 付きバックアップを作成します。

## ヘルスチェック（doctor）

Claude Code:

```bash
bash doctor.sh
```

確認項目：
- `jq` の存在
- `settings.json` の正当性
- `statusLine` の正しい配線
- 両 hook の登録状態
- スクリプトファイルの存在と実行権限
- 最新の ctx 値（直近セッション）

Codex:

```bash
bash adapters/codex/doctor.sh
```

確認項目：
- `jq` / `awk` / `codex` の存在
- `~/.codex/config.toml` に self-context hook が登録されていること
- `codex --strict-config --version` で config が parse できること
- hook script の存在と実行権限
- 最新 rollout JSONL から `additionalContext` を生成できること

## 設定

### 環境変数

| 変数 | デフォルト | 説明 |
|------|----------|------|
| `SELFCTX_CTX_STATE_DIR` | `~/.claude/.ctx-state` | セッションごとの ctx ファイル保存先 |
| `SELFCTX_STATUSLINE_CMD` | （なし） | 委譲先の既存 statusLine コマンド |
| `SELFCTX_CORE_DIR` | `<install>/core` | core/emit-injection.sh のパス |

Codex adapter:

| 変数 | デフォルト | 説明 |
|------|----------|------|
| `CODEX_HOME` | `~/.codex` | Codex config / rollout ディレクトリ |
| `SELFCTX_CTX_STATE_DIR` | `~/.codex/.ctx-state` | セッションごとの ctx ファイル保存先 |
| `SELFCTX_CORE_DIR` | `<install>/core` | core/emit-injection.sh のパス |

### PostToolUse matcher: Agent と Task

Claude Code の環境によって、サブエージェントのツール名が `Agent` または `Task` と異なる場合があります。
`install.sh` は両方の matcher を登録します。二重発火が発生する場合は、不要な方を `settings.json` から削除してください。

## stable 対象: Claude Code（v1）

`statusLine` および `hooks.UserPromptSubmit` / `hooks.PostToolUse` は Claude Code 固有の機構です。
他ホストでは別アダプターが必要です：

- Codex CLI: experimental アダプターを同梱しています。`statusLine` ではなく rollout JSONL を使います
- OpenCode（部分的な hooks サポート、毎ターン注入は 2026-06-02 時点で未確認）
- Cursor、Windsurf、Gemini CLI 等

## experimental: Codex CLI アダプター

`adapters/codex/hook-injector.sh` は Codex CLI 向けの **experimental** アダプターです。

インストーラーは同じ hook 設定を `~/.codex/config.toml` に書き込みます。これは通常の
Codex CLI と、同じ Codex home を使う現行の Codex Desktop build で共有される設定場所です。
Desktop 側が別の Codex home を使っている場合は、`CODEX_HOME` または `--codex-home` を指定してください。

hook stdin の `transcript_path` を読み、rollout JSONL から最新の `token_count` イベントを取得し、
Codex TUI と同一の式でパーセンテージを計算します（`codex-rs/tui/src/token_usage.rs` 由来）:

```
BASELINE = 12000
effective_window = model_context_window - BASELINE
used             = max(last_token_usage.total_tokens - BASELINE, 0)
remaining        = max(effective_window - used, 0) / effective_window * 100
```

- `last_token_usage.total_tokens`（= input_tokens + output_tokens of current turn）を使用します。
  `input_tokens` 単独は ~2–4% 過小評価になるため使用しません。
- `total_token_usage`（累積セッション合計）は使用しません。`model_context_window` を超える場合があるためです。

**現状**: feasibility 確認済み。TUI 表示値との完全一致を OSS ソース解析で確認済み (2026-06-03)。

詳細は `adapters/codex/README.md` を参照してください。

## ホストごとの価値

| ホスト | 価値の種類 | 実現できること |
|--------|-----------|--------------|
| **Claude Code** | enabling（自律化を可能にする） | Claude が毎ターン残コンテキスト量を認識し、handoff 等を自律判断できる |
| **Codex CLI**（experimental） | automating（自動化） | transcript JSONL 解析による同等の自己認識 |
| **OpenCode** | 調査中 | 毎ターン hook とトークン公開 API が必要 |

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

## リリースノート・変更履歴

[RELEASE.md](RELEASE.md) を参照。
