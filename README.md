# codex-workbench.nvim

Review-first Neovim client for Codex App Server.

codex-workbench.nvim runs Codex in a shadow git worktree and applies only
approved review patches back to the real workspace. The Lua runtime uses only
Neovim standard APIs; the Rust bridge owns app-server JSONL, shadow sync,
diff generation, and patch application.

## Requirements

- Neovim >= 0.10
- Git repository
- `codex-cli >= 0.124.0`
- macOS or Linux

## Quickstart

```lua
require("codex_workbench").setup()
```

Build the bridge during development:

```sh
cargo build --manifest-path rust/Cargo.toml
```

Then use:

```vim
:CodexWorkbenchAsk refactor @this
:CodexWorkbenchThreads
:CodexWorkbenchReview
:CodexWorkbenchAccept all
```

`:CodexWorkbenchAsk` first lists Codex threads for the current repository
project, then lets you choose an existing thread or start a new one before the
prompt is sent. Workbench threads run with `cwd` set to the stable shadow
worktree for that repository, so the real worktree is still not exposed to
Codex edits.

Scope forms for accept/reject are `all`, `file:path`, and `hunk:path:index`.
In the review buffer, `a/r` accepts or rejects all, `A/R` works on the file
under the cursor, and `h/x` works on the hunk under the cursor.

## Design

- Codex app-server always runs with `cwd` set to the shadow worktree.
- Real workspace changes are synced into shadow before a prompt only when there
  is no pending review.
- Final review patches are generated from the shadow worktree after a turn
  completes.
- New files created by Codex in shadow are included in the final review patch.
- Binary, rename, mode, symlink, and submodule-like changes are treated as
  file-level review items.

## Commands

- `:CodexWorkbenchOpen`
- `:CodexWorkbenchAsk [prompt]`
- `:CodexWorkbenchReview`
- `:CodexWorkbenchThreads`
- `:CodexWorkbenchAccept [scope]`
- `:CodexWorkbenchReject [scope]`
- `:CodexWorkbenchAbandon`
- `:CodexWorkbenchResume [thread_id]`
- `:CodexWorkbenchFork`
- `:CodexWorkbenchStatus`
- `:CodexWorkbenchToggleDetails`
- `:CodexWorkbenchLogs`
- `:CodexWorkbenchHealth`
- `:CodexWorkbenchInstallBinary`
