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

## Installation

**lazy.nvim:**

```lua
{
  "KotaroMotoda/codex-workbench.nvim",
  build = "cargo build --manifest-path rust/Cargo.toml",
  config = function()
    require("codex_workbench").setup({
      -- see Configuration section for all options
    })
  end,
}
```

**Manual / dev:**

```lua
require("codex_workbench").setup()
```

Build the bridge manually:

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

## Configuration

All options with their defaults:

```lua
require("codex_workbench").setup({
  -- Command used to invoke the Codex CLI
  codex_cmd = "codex",

  -- Bridge binary
  binary = {
    auto_install = false,   -- download binary on first use
    path = nil,             -- explicit path; overrides auto-discovery
  },

  -- UI windows
  ui = {
    output = {
      position = "right",   -- "right" | "bottom"
      size = 40,            -- columns (right) or rows (bottom)
    },
    review = {
      layout = "vertical",  -- "vertical" | "horizontal"
    },
  },

  -- Session
  session = {
    auto_resume = true,     -- initialize bridge on Neovim startup
  },

  -- Shadow worktree (where Codex runs its edits)
  shadow = {
    root = vim.fn.stdpath("state") .. "/codex-workbench/shadows",
    max_untracked_file_bytes = 5 * 1024 * 1024,    -- 5 MB per file
    max_untracked_total_bytes = 50 * 1024 * 1024,  -- 50 MB total
  },

  -- Context markers available in prompts
  contexts = {
    enabled = {
      this        = true,  -- @this  → current file:line
      buffer      = true,  -- @buffer → full buffer text
      selection   = true,  -- @selection → visual selection
      diagnostics = true,  -- @diagnostics → LSP diagnostics
      changes     = true,  -- @changes → git diff of current file
      file        = true,  -- @file(path) → file contents
    },
  },

  statusline = { enabled = true },
})
```

## Limitations

- Only one Neovim instance per workspace is supported. The bridge holds an exclusive lock on the workspace state directory; a second instance will refuse to initialize and report `workspace_locked`.
- Visual-selection context (`@selection`) is only captured when `:CodexWorkbenchAsk` is invoked from visual mode.
- Binary files, submodule changes, and symlinks are reviewed as entire file items — hunk-level accept/reject is not available for them.
- `@changes` context uses `git diff` with a 2-second timeout. In very large repositories this may time out and return an empty diff; use `@file(path)` instead when the file is large.
- Shadow worktree sync copies only tracked files and untracked files under the configured byte limits (`shadow.max_untracked_file_bytes`, `shadow.max_untracked_total_bytes`).
