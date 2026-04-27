# Contributing

## Prerequisites

- Rust stable toolchain (`rustup toolchain install stable`)
- Neovim ≥ 0.10 with [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `cargo-audit` for security scanning (`cargo install cargo-audit`)

## Development workflow

```bash
# Build the bridge binary
cd rust && cargo build

# Run Rust tests
cd rust && cargo test --all

# Lint
cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings

# Run Lua specs (from repo root)
nvim --headless -c "PlenaryBustedDirectory tests/spec {minimal_init='tests/minimal_init.lua'}" -c "qa"

# Run a single spec
nvim --headless -c "PlenaryBustedFile tests/spec/bridge_spec.lua" -c "qa"
```

## Architecture

Two-layer design:
1. **Lua layer** (Neovim frontend) — commands, UI, context resolution, key mappings
2. **Rust bridge** (`rust/`) — stdio JSONL dispatcher that owns the shadow worktree and communicates with Codex app-server

The Lua ↔ Rust protocol uses line-delimited JSON. Requests carry an `id`; events have an `event` field and no `id`.

Key Rust crates:
- `protocol` — wire types and `BridgeError` (21 typed variants)
- `core` — business logic: shadow worktree, git operations, session state
- `bridge` — stdio dispatcher (reads requests, dispatches to core, emits events)

## Pull request guidelines

- Keep PRs focused — one concern per PR
- Add or update Lua specs under `tests/spec/` for Lua behaviour changes
- Add or update Rust tests under `rust/crates/*/tests/` or inline `#[cfg(test)]` for Rust changes
- All CI checks must pass before merge
- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages

## Known limitations

- Neovim ≥ 0.10 is required (uses `vim.system`, `vim.uv`, `vim.json`)
- Only one Neovim instance per workspace is supported (workspace lock enforced by the bridge)
- Visual-selection context (`@selection`) is only captured if the command is triggered from visual mode
