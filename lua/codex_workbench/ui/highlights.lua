local M = {}

M.namespace = vim.api.nvim_create_namespace("codex_workbench/review")

local groups = {
  { "CodexAdd", { link = "DiffAdd" } },
  { "CodexDelete", { link = "DiffDelete" } },
  { "CodexChange", { link = "DiffChange" } },
  { "CodexAddSign", { link = "GitSignsAdd" } },
  { "CodexDeleteSign", { link = "GitSignsDelete" } },
  { "CodexChangeSign", { link = "GitSignsChange" } },
  { "CodexPending", { link = "WarningMsg" } },
  { "CodexAccepted", { link = "DiagnosticOk" } },
  { "CodexRejected", { link = "Comment" } },
  { "CodexBadge", { link = "Special" } },
  { "CodexBadgeMuted", { link = "Comment" } },
  { "CodexWinbar", { link = "WinBar" } },
  { "CodexWinbarKey", { link = "Keyword" } },
  { "CodexWinbarValue", { link = "String" } },
  { "CodexWinbarMuted", { link = "Comment" } },
}

local sign_fallbacks = {
  CodexAddSign = "DiffAdd",
  CodexDeleteSign = "DiffDelete",
  CodexChangeSign = "DiffChange",
}

function M.setup()
  for _, group in ipairs(groups) do
    local name, opts = group[1], vim.tbl_extend("force", { default = true }, group[2])
    if sign_fallbacks[name] and vim.fn.hlexists(opts.link) == 0 then
      opts.link = sign_fallbacks[name]
    end
    vim.api.nvim_set_hl(0, name, opts)
  end
end

---@param buf integer
---@param lnum integer zero-based line number
---@param group string
---@param sign string|nil
---@param sign_group string|nil
---@param signs_enabled boolean|nil
function M.mark_line(buf, lnum, group, sign, sign_group, signs_enabled)
  local opts = {
    line_hl_group = group,
  }
  if signs_enabled ~= false and sign then
    opts.sign_text = sign
    opts.sign_hl_group = sign_group or group
  end
  vim.api.nvim_buf_set_extmark(buf, M.namespace, lnum, 0, opts)
end

return M
