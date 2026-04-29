# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Phase 4: OSS polish
  - Version-agnostic binary discovery (`bin/*/codex-workbench-bridge` glob)
  - Structured JSONL logging with human-readable `:CodexWorkbenchLogs` view
  - LuaCATS type annotations on public APIs (`init.lua`, `bridge.lua`, `error_codes.lua`)
  - 2-second timeout on `git diff` subprocess in context resolution
- Backend-neutral bridge groundwork (issue #44, P0)
  - `codex` cargo feature (default on); `--no-default-features` builds the bridge without the Codex app-server client
  - `stage_begin` / `stage_finalize` bridge methods for backend-neutral external write transactions (codecompanion shadow-review extension)
  - `BridgeError::CodexBackendDisabled` and `BridgeError::NoActiveStage` variants with matching Lua localizations

## [0.1.0] - 2025-01-01

### Added
- Shadow git worktree isolation — Codex edits run in an isolated worktree; only approved patches apply to the real workspace
- Review-first workflow: `review_created` → accept / reject / abandon per-file or per-hunk
- Typed bridge errors with 21 stable `snake_case` error codes
- Idempotency and crash-safety: `PendingApply` state tracking, atomic writes via named temp files
- Workspace locking (prevents concurrent Neovim instances from racing on the same session)
- Lua spec suite: bridge, context, commands, review UI, thread picker, error codes
- Rust fixture tests for `apply_patch` (add, modify, rename, chmod, mismatch)
- Weekly `cargo audit` CI workflow
