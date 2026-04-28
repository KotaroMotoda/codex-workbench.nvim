vim.opt.rtp:prepend(vim.fn.getcwd())
require("codex_workbench").setup({ session = { auto_resume = false } })

-- Verify the error-code translation table covers every variant the Rust
-- bridge can emit. Drift between the Rust enum and this Lua mapping would
-- cause unlocalized fallbacks, so we treat missing entries as a hard failure.
do
  local error_codes = require("codex_workbench.error_codes")
  local expected = {
    "not_initialized",
    "invalid_request",
    "unknown_method",
    "not_a_git_repository",
    "git_failed",
    "patch_apply_failed",
    "scope_invalid",
    "scope_file_not_found",
    "scope_hunk_not_found",
    "no_pending_review",
    "review_pending",
    "real_workspace_changed",
    "app_server_crashed",
    "app_server_error",
    "turn_failed",
    "no_thread",
    "io_error",
    "internal_error",
    -- Phase 2
    "state_unavailable",
    "workspace_locked",
    "shadow_unavailable",
  }
  for _, code in ipairs(expected) do
    assert(type(error_codes.messages[code]) == "string", "error_codes.messages missing entry for " .. code)
  end

  local localized = error_codes.format({ ok = false, error_code = "patch_apply_failed", error = "raw" })
  assert(
    localized == error_codes.messages.patch_apply_failed,
    "error_codes.format should prefer the localized message for known codes"
  )

  local fallback = error_codes.format({ ok = false, error = "raw fallback" })
  assert(fallback == "raw fallback", "error_codes.format should fall back to the raw message")

  local truncated = error_codes.format({ ok = false, error = string.rep("x", 500) })
  assert(#truncated <= 205, "error_codes.format should bound fallback length")
end

assert(type(require("codex_workbench.context").snapshot) == "function", "context.snapshot must exist")

for _, command in ipairs({
  "CodexWorkbenchOpen",
  "CodexWorkbenchAsk",
  "CodexWorkbenchReview",
  "CodexWorkbenchThreads",
  "CodexWorkbenchAccept",
  "CodexWorkbenchReject",
  "CodexWorkbenchAbandon",
  "CodexWorkbenchResume",
  "CodexWorkbenchFork",
  "CodexWorkbenchStatus",
  "CodexWorkbenchToggleDetails",
  "CodexWorkbenchLogs",
  "CodexWorkbenchHealth",
  "CodexWorkbenchInstallBinary",
}) do
  assert(vim.api.nvim_get_commands({})[command], command .. " was not registered")
end

local selected_thread_id = nil
vim.ui.select = function(items, opts, callback)
  assert(#items == 2, "thread picker should include new thread and one existing thread")
  local rendered = opts.format_item(items[2])
  assert(rendered:find("existing thread", 1, true), rendered)
  assert(rendered:find("notLoaded", 1, true), rendered)
  callback(items[2])
end

require("codex_workbench.ui.thread_picker").select({
  project = {
    workspace = vim.fn.getcwd(),
    current_thread_id = vim.NIL,
  },
  threads = {
    {
      id = "thread-1",
      name = vim.NIL,
      preview = "existing thread",
      status = "notLoaded",
      source = "cli",
      updated_at = 1777036069,
    },
  },
}, function(selection)
  selected_thread_id = selection and selection.thread_id
end)

assert(selected_thread_id == "thread-1", "thread picker did not return the selected thread")
