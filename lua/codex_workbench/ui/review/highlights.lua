local M = {}

M.namespace = vim.api.nvim_create_namespace("codex_workbench/review")

function M.setup()
  vim.api.nvim_set_hl(0, "CodexAdd", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "CodexDelete", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CodexChange", { default = true, link = "DiffChange" })
  vim.api.nvim_set_hl(0, "CodexPending", { default = true, link = "WarningMsg" })
  vim.api.nvim_set_hl(0, "CodexAccepted", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CodexRejected", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexWinbar", { default = true, link = "WinBar" })
  vim.api.nvim_set_hl(0, "CodexWinbarKey", { default = true, link = "Keyword" })
  vim.api.nvim_set_hl(0, "CodexWinbarValue", { default = true, link = "String" })
  vim.api.nvim_set_hl(0, "CodexWinbarMuted", { default = true, link = "Comment" })
end

---@param buf integer
---@param lnum integer zero-based line number
---@param group string
---@param sign string|nil
function M.mark_line(buf, lnum, group, sign)
  local opts = {
    line_hl_group = group,
    sign_text = sign,
    sign_hl_group = group,
  }
  local ok = pcall(vim.api.nvim_buf_set_extmark, buf, M.namespace, lnum, 0, opts)
  if not ok then
    opts.sign_text = nil
    opts.sign_hl_group = nil
    pcall(vim.api.nvim_buf_set_extmark, buf, M.namespace, lnum, 0, opts)
  end
end

return M
