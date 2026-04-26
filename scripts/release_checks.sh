#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cargo test --manifest-path rust/Cargo.toml
nvim --headless -u NONE -c "set rtp^=$repo_root" -c "lua require('codex_workbench').setup({ session = { auto_resume = false } })" -c "quit"
nvim --headless -u NONE -c "set rtp^=$repo_root" -c "luafile tests/nvim/smoke.lua" -c "quit"
