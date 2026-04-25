vim.opt.rtp:prepend(vim.fn.getcwd())
require("codex_workbench").setup({ session = { auto_resume = false } })

for _, command in ipairs({
  "CodexWorkbenchOpen",
  "CodexWorkbenchAsk",
  "CodexWorkbenchReview",
  "CodexWorkbenchAccept",
  "CodexWorkbenchReject",
  "CodexWorkbenchResume",
  "CodexWorkbenchFork",
  "CodexWorkbenchStatus",
  "CodexWorkbenchHealth",
  "CodexWorkbenchInstallBinary",
}) do
  assert(vim.api.nvim_get_commands({})[command], command .. " was not registered")
end

