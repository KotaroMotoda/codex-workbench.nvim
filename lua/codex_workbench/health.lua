local M = {}

function M.check(opts)
  vim.health.start("codex-workbench.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 is required")
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git is available")
  else
    vim.health.error("git is required")
  end

  local codex_cmd = opts.codex_cmd or "codex"
  if vim.fn.executable(codex_cmd) == 1 then
    vim.health.ok(codex_cmd .. " is available")
  else
    vim.health.error(codex_cmd .. " is required")
  end

  local bridge = require("codex_workbench.bridge")
  local error_codes = require("codex_workbench.error_codes")
  bridge.request("health", {}, function(response)
    if response.ok then
      vim.health.ok("bridge responded")
    else
      vim.health.error(error_codes.format(response))
    end
  end)
end

return M
