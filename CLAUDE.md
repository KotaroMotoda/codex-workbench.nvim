# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**codex-workbench.nvim** is a Neovim plugin providing a review-first client for the Codex App Server. Its core design is **shadow git worktree isolation**: Codex edits run in a separate git worktree; only user-approved changes are applied back to the real workspace.

## Critical Guidance
簡潔な日本語で回答してください.

この環境の `distill` の既定設定は `Ollama + qwen3.5:2b` です.

CRITICAL: 大きい非対話コマンド出力を読むときは, raw output が明示的に必要な場合を除き, まず `distill` を使って要約してから判断してください.
対象例: テスト結果, ログ, スタックトレース, `git diff`, `rg`, `find`, `ls -la`, `npm audit`, `terraform plan`.

CRITICAL: `distill` への指示は必ず具体的にしてください. 何を知りたいか, 何を含めるか, 出力形式を明示してください.
例: `Return only the filenames.` `Return valid JSON only.` `Return only: PASS or FAIL, followed by failing test names if any.`
曖昧な依頼は避けてください.

CRITICAL: `distill` が終わるまで待ってから次に進んでください.

`distill` を使わない条件:
- 正確な生出力が必要なとき
- 対話的なコマンドや TUI を扱うとき
- 出力が短く, そのまま確認した方が明確なとき

パイプ後も終了コードを厳密に扱いたいときは, `pipefail` を考慮してください.

## Common Commands

### Build

```bash
# Debug build
cargo build --manifest-path rust/Cargo.toml

# Release build (cross-compile targets: aarch64-apple-darwin, x86_64-apple-darwin, x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu)
cargo build --manifest-path rust/Cargo.toml --release --target <target>
```

### Lint

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
```

### Test

```bash
# All Rust tests
cargo test --manifest-path rust/Cargo.toml

# Single Rust test
cargo test --manifest-path rust/Cargo.toml <test_name>

# Lua plenary specs
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/spec/ { minimal_init = 'tests/minimal_init.lua' }" +q

# Lua smoke test
nvim --headless -u NONE -c "set rtp^=." \
  -c "luafile tests/nvim/smoke.lua" -c "quit"
```

## Architecture

The project has two layers communicating over **stdio JSONL (newline-delimited JSON-RPC)**:

```
Neovim (Lua)  ←→  Bridge binary (Rust, stdio JSONL)  ←→  Manager (Rust)
                                                              ├→ AppServerClient  (spawns `codex app-server`)
                                                              ├→ ShadowWorkspace  (git worktree management)
                                                              ├→ GitRepo          (git command wrapper)
                                                              └→ SessionState     (JSON, crash recovery)
```

### Rust workspace (`rust/crates/`)

| Crate | Role |
|-------|------|
| `protocol` | JSONL wire types: `BridgeRequest`, `BridgeResponse`, `BridgeEvent`, `BridgeError` (21 typed variants with stable snake_case codes) |
| `core` | All business logic — state machine (`manager.rs`), shadow worktree (`shadow.rs`), git wrapper (`git.rs`), patch parsing & scope filtering (`review.rs`), session state with crash recovery (`state.rs`), error classification pipeline (`errors.rs`) |
| `bridge` | Thin stdin/stdout dispatcher; reads JSONL, calls `Manager`, writes JSONL |

### Lua frontend (`lua/codex_workbench/`)

| File | Role |
|------|------|
| `init.lua` | Setup entry point; registers Neovim commands |
| `bridge.lua` | Spawns bridge subprocess, handles JSONL I/O, emits typed events |
| `commands.lua` | `:CodexWorkbench*` command handlers |
| `config.lua` | Configuration defaults |
| `context.lua` | Context resolution (`@this`, `@buffer`, `@selection`, etc.) |
| `error_codes.lua` | Maps bridge error codes → localized one-line messages |
| `ui/review.lua` | Review buffer; key bindings `a`/`r` (all), `A`/`R` (file), `h`/`x` (hunk) |
| `ui/output.lua` | Streaming output window |
| `ui/thread_picker.lua` | Thread selection UI |
| `ui/statusline.lua` | Statusline integration |

### Tests

| Path | Scope |
|------|-------|
| `rust/crates/core/tests/manager_integration.rs` | Integration tests: initialize, ask, accept/reject (mocks AppServer) |
| `rust/fuzz/` | Libfuzzer targets for patch parsing and error classification |
| `tests/spec/` | Plenary specs: error code coverage, thread picker |
| `tests/nvim/smoke.lua` | Command registration and basic invariants |

## Key Design Decisions

### Error handling
- Rust: 21 typed `BridgeError` variants; each has a stable `code`, optional structured `details` (file paths, stderr tails), and a display string.
- Lua: `error_codes.lua` maps codes to localized messages; unknown codes fall back to the raw error truncated to 200 chars.
- Full error payloads are always written to the log file; only short summaries are shown in UI.

### Crash safety (Phase 2)
- `PendingApply` in `state.rs` tracks apply stage (`Applying → Applied → ShadowResyncing`); on restart an in-progress apply can be resumed idempotently.
- Session state is stored at `~/.local/share/nvim/state/codex-workbench/<workspace_hash>/state.json` with a `.bak` copy created before each write.

### Shadow worktree lifecycle
- Created under `shadow.root` (default `~/.local/share/nvim/state/codex-workbench/shadows`).
- Stale worktrees (not in `git worktree list`) are detected and pruned on startup.
- Untracked files are copied from real workspace up to configurable size limits (5 MB per file, 50 MB total).

### Scope filtering
- `review.rs` parses unified diffs and supports three granularities: `all`, `file:<path>`, `hunk:<path>:<index>`.
- `patch_for_scope()` extracts the relevant hunks; `remaining_after_scope()` returns what is left after a partial accept/reject.
