local M = {}

function M.open_log()
  require("codex_workbench.log").open()
end

function M.retry_last()
  require("codex_workbench.commands").retry_last()
end

function M.restart_bridge(response)
  local config = require("codex_workbench.config").current or require("codex_workbench.config").setup({})
  require("codex_workbench.bridge").initialize(config, function(init_response)
    if init_response and init_response.ok then
      vim.notify("Codex bridge restarted", vim.log.levels.INFO, { title = "codex-workbench" })
      return
    end
    require("codex_workbench.ui.error_prompt").show(init_response or response)
  end)
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
