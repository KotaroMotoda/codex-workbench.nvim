vim.opt.rtp:prepend(vim.fn.getcwd())
require("codex_workbench").setup({ session = { auto_resume = false } })

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
