local M = {}

M.defaults = {
  codex_cmd = "codex",
  binary = {
    auto_install = false,
    path = nil,
  },
  ui = {
    output = {
      position = "right",
      size = 40,
    },
    review = {
      layout = "vertical",
    },
  },
  session = {
    auto_resume = true,
  },
  shadow = {
    root = vim.fn.stdpath("state") .. "/codex-workbench/shadows",
    max_untracked_file_bytes = 5242880,
    max_untracked_total_bytes = 52428800,
  },
  contexts = {
    enabled = {
      this = true,
      buffer = true,
      selection = true,
      diagnostics = true,
      changes = true,
      file = true,
    },
  },
  keymaps = {},
  statusline = {
    enabled = true,
  },
}

function M.setup(opts)
  return vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M

