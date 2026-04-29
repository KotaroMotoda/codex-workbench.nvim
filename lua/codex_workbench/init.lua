local M = {}

---@param opts table|nil
---@return table
function M.setup(opts)
  M.opts = require("codex_workbench.config").setup(opts)
  local highlights = require("codex_workbench.ui.highlights")
  highlights.setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CodexWorkbenchHighlights", { clear = true }),
    callback = highlights.setup,
  })
  require("codex_workbench.ui.progress").configure(M.opts.ui.progress)
  require("codex_workbench.ui.error_prompt").configure(M.opts.errors)
  require("codex_workbench.commands").register(M.opts)
  if M.opts.session.auto_resume then
    require("codex_workbench.bridge").initialize(M.opts)
  end
  return M
end

---@param prompt string|nil
function M.ask(prompt)
  M.opts = M.opts or require("codex_workbench.config").setup({})
  local bridge = require("codex_workbench.bridge")
  local context = require("codex_workbench.context")
  local output = require("codex_workbench.ui.output")
  local log = require("codex_workbench.log")
  local error_codes = require("codex_workbench.error_codes")
  local error_prompt = require("codex_workbench.ui.error_prompt")

  local function report(response)
    -- Stop the progress toast first; otherwise the spinner keeps
    -- rotating over the error notification.
    require("codex_workbench.ui.progress").done("Error", 0)
    log.write("ERROR", "bridge_error", response)
    vim.notify(
      error_codes.format(response) .. "\nLog: " .. log.path(),
      vim.log.levels.ERROR,
      { title = "codex-workbench" }
    )
    error_prompt.show(response)
  end

  require("codex_workbench.ui.review.highlights").setup()
  require("codex_workbench.ui.progress").configure(M.opts.ui.progress)
  require("codex_workbench.ui.error_prompt").configure(M.opts.errors)
  output.open()
  output.start_turn()
  require("codex_workbench.ui.progress").set("Asking")
  bridge.initialize(M.opts, function(init_response)
    if not init_response.ok then
      report(init_response)
      return
    end
    bridge.request("ask", { prompt = context.resolve(prompt or "", M.opts) }, function(response)
      if not response.ok then
        report(response)
      end
    end)
  end)
end

---@return string
function M.statusline()
  return require("codex_workbench.ui.statusline").component()
end

return M
