local M = {}

function M.setup(opts)
  M.opts = require("codex_workbench.config").setup(opts)
  require("codex_workbench.commands").register(M.opts)
  if M.opts.session.auto_resume then
    require("codex_workbench.bridge").initialize(M.opts)
  end
  return M
end

function M.ask(prompt)
  M.opts = M.opts or require("codex_workbench.config").setup({})
  local bridge = require("codex_workbench.bridge")
  local context = require("codex_workbench.context")
  require("codex_workbench.ui.output").open()
  bridge.initialize(M.opts, function(init_response)
    if not init_response.ok then
      vim.notify(init_response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      return
    end
    bridge.request("ask", { prompt = context.resolve(prompt or "", M.opts) }, function(response)
      if not response.ok then
        vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      end
    end)
  end)
end

function M.statusline()
  return require("codex_workbench.ui.statusline").component()
end

return M
