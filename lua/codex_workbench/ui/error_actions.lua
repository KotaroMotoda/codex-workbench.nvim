local M = {}

function M.open_log()
  require("codex_workbench.log").open()
end

function M.retry_last()
  require("codex_workbench.commands").retry_last()
end

function M.open_shadow_root()
  local config = require("codex_workbench.config").current or require("codex_workbench.config").setup({})
  local root = config.shadow and config.shadow.root
  if not root or root == "" then
    vim.notify("shadow root is not configured", vim.log.levels.WARN, { title = "codex-workbench" })
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(root))
end

function M.reopen_review()
  require("codex_workbench.ui.review").reopen()
end

return M
