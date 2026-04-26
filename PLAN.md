# codex-workbench.nvim — 実装方針 / 引き継ぎノート

このドキュメントは、`codex-workbench.nvim` を OSS として「昨今の人気 Lua / Rust
プロジェクトと並べても恥ずかしくない品質」に引き上げるための作業計画と、
これまでの進捗を引き継ぎ用にまとめたもの。次セッションはこのファイルを
最初に読み、次に `README.md` → `lua/codex_workbench/init.lua` →
`rust/crates/core/src/manager.rs` の順で読めば把握が速い。

---

## 0. プロジェクト概要 (前提知識)

- **何を作っているか**: Codex App Server (`codex app-server --listen
  stdio://`) を Neovim から呼び出すクライアント。Codex の編集は **shadow
  git worktree** に閉じ込めて、ユーザがレビューで accept した hunk だけが
  実 worktree に適用される。
- **構成**:
  - `lua/codex_workbench/` — Neovim 標準 API のみ使う Lua ランタイム
    (UI / commands / bridge IO ラッパ)。
  - `rust/crates/protocol` — Lua ↔ Rust 間の JSONL スキーマ。
  - `rust/crates/core` — bridge のロジック (manager, app_server,
    git, shadow, review, state)。
  - `rust/crates/bridge` — `core::Manager` を stdio で駆動するだけの
    薄いバイナリ。
- **ライフサイクル**:
  1. Lua の `setup()` が `bridge.initialize` を呼び、Rust 側で git
     repo discover → shadow worktree 作成 → state.json load。
  2. ユーザが `:CodexWorkbenchAsk` で prompt を投げると、Rust が shadow
     を実 worktree から再同期 → Codex に turn を投げる → 完了後、
     shadow の差分から review patch を生成。
  3. レビュー UI で accept / reject / hunk 単位選択 → 実 worktree に
     `git apply --3way` で適用。

---

## 1. 進捗サマリ

| Phase | 概要 | 状態 |
| --- | --- | --- |
| Phase 1 | 構造化された bridge エラーと localized notification | **完了** (branch `feat/typed-bridge-errors`, commit `96bec72`) |
| Phase 2 | 冪等性 / クラッシュセーフティ | 未着手 |
| Phase 3 | テスト強化 | 未着手 |
| Phase 4 | OSS 作法 (CHANGELOG, version 一元化, 構造化ログ, 型注釈) | 未着手 |

---

## 2. Phase 1 完了内容

### 2.1 何を直したか
- ユーザに見える notification から「生の stderr 行」「生の JSON」「`bridge
  exited with code N`」「`git failed: <stderr>`」が漏れる経路を全て塞いだ。
- Rust 側で 18 種の `BridgeError` variant を定義し、stable な
  snake_case `code` を割り当てた。
- Lua 側は `error_code` を localized メッセージに変換するテーブルだけを
  使って `vim.notify` する。詳細はログファイルへ誘導。

### 2.2 追加 / 変更ファイル
- 新規:
  - `rust/crates/protocol/src/error.rs` — `BridgeError` enum + `ErrorPayload`
    wire format。`code()` / `details()` ヘルパ。
  - `rust/crates/core/src/errors.rs` — `classify(anyhow::Error)
    -> BridgeError`。typed errors を pass-through、`GitInvocationError`
    と `io::Error` は専用 variant に、それ以外は 240 字に truncate した
    `Internal { message }` に潰す。
  - `lua/codex_workbench/error_codes.lua` — `code → 1 行メッセージ` の
    `messages` テーブルと `format(value)`、`is_ok(response)`。
- 変更:
  - `protocol::BridgeResponse` に `error_code`, `error_details` を追加
    (`error` 文字列は後方互換のため維持)。
  - `core::git`: `git_bytes` の失敗を `GitInvocationError` (`pub
    command, stderr, stderr_tail`) で返す。`GitRepo::discover` は
    `BridgeError::NotAGitRepository` を生成。
  - `core::manager`: 既知の境界エラーをすべて `BridgeError` で返す
    (`UnknownMethod`, `NotInitialized`, `NoPendingReview`,
    `ReviewPending`, `RealWorkspaceChanged`, `NoThread`,
    `PatchApplyFailed`)。`accept` の patch 失敗時は
    `GitInvocationError::stderr_tail` のみを伝搬。
  - `core::review`: `patch_for_scope` / `remaining_after_scope` の
    エラーを `ScopeInvalid` / `ScopeFileNotFound` / `ScopeHunkNotFound`
    に。`parse_hunk_scope` ヘルパを抽出。
  - `core::app_server`: `parse_remote_error` で remote 由来の `code` /
    `message` のみ抽出 (240 字上限)。EOF は `AppServerCrashed`、
    `turn/completed.error` は `TurnFailed`。`read_message` で
    `stderr_tail_text` を保持。
  - `bridge/main.rs`: `classify(err)` 経由で `BridgeResponse::err(id,
    &bridge_error)` を返す。JSONL parse 失敗時の `error` event も
    `code/message/details` schema に。
  - Lua 側の生 `response.error` 直渡しを全部 `error_codes.format` 経由に
    統一: `bridge.lua`, `commands.lua`, `init.lua`, `ui/review.lua`,
    `health.lua`。`bridge.lua::on_stderr` は **log のみ** に。
  - `tests/nvim/smoke.lua` に 18 variant の translation 整合チェック +
    truncate / fallback テストを追加。

### 2.3 追加したテスト
- `rust/crates/protocol/src/error.rs::tests` — 4 件 (no_pending_review の
  null details, git_failed の details, JSON round-trip, code 一意性)。
- `rust/crates/core/src/errors.rs::tests` — 4 件 (typed pass-through, git
  classify, unknown→internal, 長文 truncate)。
- `tests/nvim/smoke.lua` — error_codes coverage と fallback。

### 2.4 やり残し / 次フェーズ持ち越し
- `core::app_server::start_thread` / `fork_thread` の `anyhow!("thread/...
  did not include a thread id")` は **Internal** に classify される。
  Phase 4 で必要なら専用 variant を切り出す。
- `core::shadow` 系の I/O エラーは現状 anyhow → Internal。Phase 2 で
  shadow 整合性チェックを実装するときに `BridgeError::Shadow*` を足す
  ほうが筋が良い。

---

## 3. Phase 2 — 冪等性 / クラッシュセーフティ (次にやる)

### 3.1 目的
中断 (panic, kill, OS crash) からの recovery と並行起動安全性。「state
が中途半端になって以降ずっと壊れている」を起こさない。

### 3.2 タスク (推奨順)

1. **`state.json` を atomic write に**
   - 対象: `rust/crates/core/src/state.rs::SessionState::save`
   - 実装: `tempfile::NamedTempFile::new_in(parent)` → 書き込み →
     `persist(path)`。fsync は要らないが、persist の前に sync は推奨。
   - load 失敗時の recovery: parse error → `state.json.bak` を試す →
     それも失敗なら `default()` + warn ログ + `BridgeError::Internal`
     ではなく新しい `BridgeError::StateUnavailable { path }` を返す。
   - テスト: tempdir で部分書き込みファイル (truncated JSON) を作って
     `SessionState::load` が回復することを確認。

2. **review apply の transactional 化**
   - 対象: `rust/crates/core/src/manager.rs::accept`
   - 現状: 「patch apply → state 更新 → shadow sync → fingerprint
     再計算 → save」の 5 段階。途中で落ちると state.json と実
     workspace が乖離する。
   - 設計案:
     - `state.json` に `pending_apply: { scope, patch_sha256,
       started_at, stage }` を追加。`stage` は
       `applying | applied | shadow_resyncing | done`。
     - 各 stage の前後で `save_state`。
     - `Manager::initialize` 起動時に `pending_apply.stage` が `done`
       以外なら `BridgeEvent::recovery_needed` を emit、ユーザに
       `:CodexWorkbenchHealth` から recovery を促す。
   - 互換性: 既存 `state.json` には `pending_apply` 欄が無い → 既定値
     `None` で OK (`#[serde(default)]`)。
   - テスト: 「stage=applying のまま reload」「stage=shadow_resyncing
     のまま reload」を fake time + tempfile で再現する。

3. **workspace lock**
   - 目的: 同 repo に複数 Neovim instance が走った場合の race を防ぐ。
   - 実装: `state_dir/.lock` を `fs2::FileExt::try_lock_exclusive`
     (依存追加: `fs2 = "0.4"`)。
   - 取得失敗時は `BridgeError::WorkspaceLocked { holder_pid: u32 }`
     (PID は `.lock` ファイルに書いておく) を返す。Lua 側 `error_codes`
     に `workspace_locked = "Another Neovim is using this workspace."`
     を追加。
   - 注意: `Manager` が `Drop` する直前に lock を release する必要が
     あり、`Manager` に `_lock: Option<File>` を持たせる。テストでは
     2 つの `Manager::new + initialize` を同 dir で起こして
     2 つ目が `WorkspaceLocked` で落ちるのを確認。

4. **shadow worktree の整合性チェック**
   - 対象: `rust/crates/core/src/shadow.rs::ShadowWorkspace::prepare`
   - 現状は `shadow_path.exists()` のみ。中身が壊れていても reuse する。
   - 実装: `git worktree list --porcelain` で shadow_path が登録済み
     worktree か確認。未登録なら `git worktree prune` → `worktree_add_detached` で再生成。
   - 失敗時は新規 variant `BridgeError::ShadowUnavailable { reason }`。

5. **install_binary.sh の SHA256 検証 + atomic move**
   - リリースに `*.sha256` を同梱 (release.yml の matrix step に追加):
     `shasum -a 256 ${{ matrix.asset }} > ${{ matrix.asset }}.sha256`。
   - `scripts/install_binary.sh`:
     - 一時 `${asset}.partial` に書く → `shasum -a 256 -c
       ${asset}.sha256` → OK なら `mv` で本番位置へ。
     - 失敗時は partial を消して exit 1。
   - 既存の `chmod +x` も `mv` の後ろに移動する。

6. **Lua 側 bridge restart で callbacks 再生成**
   - 対象: `lua/codex_workbench/bridge.lua::on_exit`
   - 現状: `M.job_id = nil` だが `M.next_id` と `M.callbacks` は古いまま。
   - 修正: `for id, cb in pairs(M.callbacks) do cb({ ok = false,
     error_code = "app_server_crashed" }) end; M.callbacks = {};
     M.next_id = 1`。
   - スモークテスト: fake job で「response が来る前に bridge が
     落ちる」シナリオを書く (Phase 3 の plenary 移行と一緒に)。

### 3.3 Phase 2 で増やす BridgeError variant 候補
```rust
StateUnavailable { path: String, reason: String },
WorkspaceLocked { holder_pid: Option<u32> },
ShadowUnavailable { reason: String },
RecoveryNeeded { stage: String },
```
全部 `error_codes.lua` 側にも 1 行ずつ追加する。

---

## 4. Phase 3 — テスト強化

### 4.1 Rust
- `rust/crates/core/src/manager.rs` を **integration テスト** で覆う。
  - `tests/manager_integration.rs` を新設し、`fake EventSink` (Vec に push) と
    `mpsc::channel` を使って `initialize → ask → review → accept` の
    happy path、`ReviewPending` リターン、`RealWorkspaceChanged`、
    `PatchApplyFailed` 等の失敗パスを網羅。
  - Codex app-server は本物を使わず `AppServerClient` を **trait 化**
    して mock を差し込めるようにする (現状は struct 直)。これは
    refactor 込み: `pub trait AppServer { fn run_turn(...) -> ...; }`
    を抽出して `Manager` が `Box<dyn AppServer>` を持つ。
  - 目安 25–40 ケース。
- `git.rs::apply_patch` の fixture テスト (tempdir + git init):
  conflict, new file, binary, rename, mode change。
- `state.rs` の atomic write / corruption recovery (Phase 2 で書く)。
- `review.rs` に `proptest` を入れる:
  - `proptest = "1"` を `[dev-dependencies]` に追加。
  - property: ランダム patch に対して `patch_for_scope(p, scope) +
    remaining_after_scope(p, scope) = 元 patch` を確認 (scope 別)。

### 4.2 Lua
- `tests/nvim/smoke.lua` の単発 assertion を **plenary.nvim busted** に
  移行する。
  - 依存: `tests/minimal_init.lua` で plenary を `git clone` する CI
    step を追加。
  - ファイル: `tests/spec/bridge_spec.lua`, `commands_spec.lua`,
    `context_spec.lua`, `error_codes_spec.lua`,
    `review_ui_spec.lua`。
  - bridge 側は fake job (`vim.fn.jobstart` を monkey-patch するか、
    LuaJIT で stdin/stdout を mock) で event 受信 → state 反映までを
    assert。

### 4.3 CI
`.github/workflows/ci.yml` を拡張:
```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-14]
steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable
    with: { components: clippy, rustfmt }
  - run: cargo fmt --all -- --check
  - run: cargo clippy --all-targets --all-features -- -D warnings
  - run: cargo test --manifest-path rust/Cargo.toml
  - uses: rhysd/action-setup-vim@v1
    with: { neovim: true, version: stable }
  - run: scripts/release_checks.sh
  - run: stylua --check lua/ tests/
  - run: luacheck lua/
```
追加で `cargo deny check` と `cargo audit` を週次 schedule で。

### 4.4 Fuzz
- `cargo-fuzz` で `files_from_patch`, `patch_for_scope`,
  `parse_diff_path` の panic 不在を fuzz target 化。リリース判定には
  必須にしない (CI で 60 秒だけ走らせる程度)。

---

## 5. Phase 4 — OSS 作法

1. **version 一元化**
   - `bridge.lua` の `0.1.0` ハードコードを廃止。
     `<data>/codex-workbench/bin/<version>/codex-workbench-bridge` を
     `vim.fn.glob` で探すか、`bridge --version` で問い合わせる。
   - GitHub release の tag は `Cargo.toml` の `[workspace.package]
     version` を `git describe` でも引けるようにする。

2. **構造化ログ**
   - `lua/codex_workbench/log.lua` を JSONL 化:
     `{ "ts": "...", "level": "INFO", "code": "bridge_event:turn_started", "details": {...} }`。
   - 既存 `[ts] LEVEL msg` 形式を読みたい開発者向けに `:CodexWorkbenchLogs`
     コマンドが pretty print する処理を入れる。

3. **LuaCATS の type annotation**
   - `init.lua`, `bridge.lua`, `error_codes.lua` の公開 API に
     `---@param`, `---@return`, `---@class` を付ける。
   - 例:
     ```lua
     ---@class CodexWorkbenchOpts
     ---@field codex_cmd string
     ---@field binary { auto_install: boolean, path: string? }
     ...
     ```

4. **`vim.system` の timeout / error 取り扱い**
   - 対象: `lua/codex_workbench/context.lua::changes`, `commands.lua`
     install path。
   - `vim.system({...}, { text = true, timeout = 2000 }):wait()` に
     して、失敗時は空文字 + `log.write("WARN", ...)`。

5. **ドキュメント / メタファイル**
   - `CHANGELOG.md` (Keep a Changelog)
   - `CONTRIBUTING.md` (build, test, commit message convention)
   - `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.md`
   - `.github/PULL_REQUEST_TEMPLATE.md`
   - README に「制限事項」「既知の問題」(Windows 未対応, multi-instance,
     approve は信頼できる action のみ等) セクションを追加。

---

## 6. プロジェクト規約 (このリポジトリの慣習)

### 6.1 ブランチ命名
- `feat/<short-kebab>` — 機能追加 / 大きい改善
- `fix/<short-kebab>` — バグ修正 (今回未使用だが、慣習として推奨)
- 既存例: `feat/add-err-handling`, `feat/add-partial-line-buffer`,
  `feat/repository-thread-picker`, `feat/typed-bridge-errors`

### 6.2 コミットメッセージ
- 1 行目: `feat: <imperative summary>` / `fix: ...` / `docs: ...`
- 本文: 何を / なぜ。Rust 側と Lua 側を両方触ったコミットは
  bullet で要点列挙。
- 末尾: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
  (Claude が一緒に書いた場合)
- 例: 過去の `feat: add partial line buffer (#3)` 参照。

### 6.3 コードスタイル
- Rust: 2021 edition, anyhow を内部で使い境界で BridgeError に classify。
  公開 API は `pub use` で re-export せず、モジュール path を使うのが
  既存の流儀。
- Lua: snake_case、`local M = {}` パターン、`vim.api.nvim_*` 標準のみ。
  外部 plugin 依存は厳禁 (README に明記)。

### 6.4 エラー追加のチェックリスト
新しいエラー条件を `BridgeError` に足すときは:
1. `rust/crates/protocol/src/error.rs` に variant を追加 (Display は
   thiserror の `#[error(...)]`)。
2. 同 file の `code()` と `details()` に分岐を追加。
3. 同 file の `tests::every_variant_has_a_unique_code` の配列にも追加。
4. `lua/codex_workbench/error_codes.lua::messages` に翻訳を追加。
5. `tests/nvim/smoke.lua` の `expected` 配列に追加。
6. 必要なら `core::errors::classify` の downcast 対象に追加。

---

## 7. サンドボックス / 環境上の注意

このリポジトリは macOS host を virtiofs (FUSE) 経由で sandbox に
mount している。Claude/CI 環境では以下の制約がある:

- **`cargo` も `nvim` も sandbox にいない**。Phase 1 では
  `cargo test` と `release_checks.sh` を **未実行** のまま commit して
  いる。push 前にホスト側で必ず両方走らせること。
- **FUSE 経由で `.git/index.lock` 等の一時ファイルが unlink できない**。
  sandbox 上で `git add` / `git commit` を回すと `warning: unable to
  unlink ...` が大量に出るが、commit 自体は成立する。残った lock は
  ホスト側で `rm .git/*.lock .git/objects/*/tmp_obj_*` で掃除。
- **Author identity**: sandbox 内で `git commit` するときは
  `git -c user.email=... -c user.name=... commit ...` 形式で渡す
  (`.gitconfig` に書き込めないため)。ユーザは `dumble203@gmail.com /
  Kotaro` を使っている。

---

## 8. 既知の小さな TODO (Phase に紐付かないもの)

- `lua/codex_workbench/bridge.lua::M.request` — `not M.job_id` で early
  return するが、callback が登録される前なので呼び側が永久に待つ
  パターンになり得る。Phase 2-6 の callback 再生成と一緒に直す。
- `lua/codex_workbench/context.lua::changes` の `vim.system` に timeout
  なし。Phase 4-4 で対応予定。
- `lua/codex_workbench/ui/output.lua` の buffer/window handle が無効に
  なったときの defensive check が弱い (`:bd` されると次回 ensure_window
  で undefined behavior 寄りに)。Phase 4 で軽く整理。
- `rust/crates/core/src/state.rs::now_unix` は `unwrap_or_default`
  に依存。time-traveling system clock 環境では 0 を吐く。実害は薄い
  ので優先度低。

---

## 9. 推奨される進め方

1. **まずホストで Phase 1 の `cargo test` と `release_checks.sh` を
   走らせる**。pass したら `feat/typed-bridge-errors` を main に PR。
2. PR が merge された前提で、`feat/atomic-state` か
   `feat/transactional-accept` ブランチを切り、Phase 2 の 1 + 2 を
   1 PR で。
3. Phase 2 の残り (lock, shadow check, install verify, callback reset)
   は別 PR に分けると review しやすい。
4. Phase 3 の plenary 移行は単独 PR で大きく動くので、Phase 2 完了後に
   一気にやる。
5. Phase 4 は文書中心なので Phase 3 と並行で OK。

各 Phase の見積もり (1 人作業前提):
- Phase 2: 2–3 日
- Phase 3: 3–5 日
- Phase 4: 1–2 日

---

## 10. 引き継ぎ時の最初の質問テンプレ

次セッションが「何から始めるか分からない」となったら、ユーザに以下を
確認すると速い:

1. Phase 1 の PR は merge されたか?
2. Phase 2 のどこから始めるか? (推奨は state atomic write → transactional accept)
3. 新しい BridgeError variant を増やす予定はあるか?
4. CI に matrix を足してよいか? (macOS runner はコストがある)
