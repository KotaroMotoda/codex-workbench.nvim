-- Maps the Rust bridge's `error_code` values to short, user-facing messages.
--
-- Bridge responses carry both a stable `error_code` (snake_case) and a
-- best-effort `error` string. The runtime prefers the localized message in
-- this table; the raw `error` string is only used as a last resort fallback
-- so that we never leak unbounded payloads into a `vim.notify` popup.

local M = {}

-- code => short, plain-language message. Keep these one-liners. Anything
-- detailed (stack traces, stderr, paths) belongs in the log file.
M.messages = {
  not_initialized = "Codex bridge is not initialized.",
  codex_not_found = "Codex bridge binary was not found.",
  bridge_spawn_failed = "Codex bridge could not be started. See the log for details.",
  invalid_request = "Codex bridge received an invalid request.",
  unknown_method = "Codex bridge received an unknown method.",
  not_a_git_repository = "This workspace is not a git repository.",
  git_failed = "A git command failed. See the log for details.",
  patch_apply_failed = "The review patch could not be applied. See the log for details.",
  scope_invalid = "The review scope is invalid.",
  scope_file_not_found = "That file is not part of the pending review.",
  scope_hunk_not_found = "That hunk is not part of the pending review.",
  no_pending_review = "There is no pending review.",
  review_pending = "Resolve the pending review before sending a new prompt.",
  real_workspace_changed = "The workspace changed while a review was pending. Refresh and try again.",
  app_server_crashed = "Codex app-server is not reachable. See the log for details.",
  app_server_error = "Codex app-server returned an error. See the log for details.",
  turn_failed = "The Codex turn failed. See the log for details.",
  no_thread = "No Codex thread is selected for this action.",
  io_error = "An I/O error occurred. See the log for details.",
  internal_error = "Codex bridge encountered an internal error. See the log for details.",
  -- Phase 2: idempotency / crash-safety
  state_unavailable = "Workspace state file is unavailable or corrupt. See the log for details.",
  workspace_locked = "Another Neovim instance is already using this workspace.",
  shadow_unavailable = "Shadow worktree is unavailable. See the log for details.",
}

M.actions = {
  codex_not_found = {
    { key = "i", label = "bridge をインストール", cmd = "CodexWorkbenchInstallBinary" },
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  bridge_spawn_failed = {
    { key = "r", label = "再試行", fn = "retry_last" },
    { key = "i", label = "bridge をインストール", cmd = "CodexWorkbenchInstallBinary" },
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  app_server_crashed = {
    { key = "r", label = "再試行", fn = "retry_last" },
    { key = "i", label = "bridge をインストール", cmd = "CodexWorkbenchInstallBinary" },
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  app_server_error = {
    { key = "r", label = "再試行", fn = "retry_last" },
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  git_failed = {
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  patch_apply_failed = {
    { key = "d", label = "差分を再表示", fn = "reopen_review" },
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  state_unavailable = {
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  workspace_locked = {
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
  shadow_unavailable = {
    { key = "p", label = "shadow root を確認", fn = "open_shadow_root" },
    { key = "l", label = "ログを開く", fn = "open_log" },
    { key = "c", label = "閉じる", default = true },
  },
}

---@param value any
---@return string|nil
function M.code(value)
  if type(value) ~= "table" then
    return nil
  end
  return value.error_code or value.code
end

---@param code string
---@return table
function M.actions_for_code(code)
  return M.actions[code] or {}
end

---@param code string|nil
---@return table
function M.actions_for(code)
  if not code then
    return {}
  end
  return M.actions_for_code(code)
end

local function trim_message(text, limit)
  limit = limit or 200
  if type(text) ~= "string" then
    return nil
  end
  -- Use vim.fn.strcharlen / vim.fn.strcharpart for correct UTF-8 character
  -- counting. Bridge error messages are mostly ASCII but may include file
  -- paths or remote error text that contains non-ASCII characters.
  if vim.fn.strcharlen(text) <= limit then
    return text
  end
  return vim.fn.strcharpart(text, 0, limit) .. "…"
end

--- Render a user-facing message for a bridge response or raw error string.
---
--- Accepts:
---   * a full bridge response (`{ ok, error_code, error, error_details }`),
---   * a `{ code = ..., message = ... }` table (event payload), or
---   * a plain string (legacy callers).
---
--- Always returns a non-empty string suitable for `vim.notify`.
---@param value any
---@return string
function M.format(value)
  if value == nil then
    return "Codex bridge returned an unknown error."
  end

  if type(value) == "string" then
    return trim_message(value) or "Codex bridge returned an unknown error."
  end

  if type(value) ~= "table" then
    return "Codex bridge returned an unknown error."
  end

  local code = M.code(value)
  if code and M.messages[code] then
    return M.messages[code]
  end

  local fallback = value.error or value.message
  return trim_message(fallback) or "Codex bridge returned an unknown error."
end

--- Returns true when the bridge response was a success (or did not carry an
--- error). Useful for `if not is_ok(response) then` style guards.
---@param response any
---@return boolean
function M.is_ok(response)
  if type(response) ~= "table" then
    return false
  end
  if response.ok == false then
    return false
  end
  return response.ok == true or response.error_code == nil
end

return M
