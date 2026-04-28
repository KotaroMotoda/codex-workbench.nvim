local highlights = require("codex_workbench.ui.review.highlights")
local panes = require("codex_workbench.ui.review.panes")
local winbar = require("codex_workbench.ui.review.winbar")

local M = {
  buf = nil,
  win = nil,
  files = {},
  selected = 1,
  opts = { winbar = true },
}

local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "codex-workbench-review-tree-" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "codex-review-tree"
  vim.bo[buf].modifiable = false
  return buf
end

local function set_modifiable(value)
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.bo[M.buf].modifiable = value
  end
end

function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

function M.attach(win)
  M.win = win
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    M.buf = create_buffer()
  end
  vim.api.nvim_win_set_buf(win, M.buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  winbar.apply(win, { kind = "review_tree" }, M.opts.winbar ~= false)
end

local function status_label(file)
  if file.binary then
    return "B"
  end
  return file.status or "M"
end

local function badge(file)
  if file.binary then
    return "[binary]"
  end
  local hunk_count = #(file.hunks or {})
  return "[" .. hunk_count .. "]"
end

function M.render(files)
  M.files = files or {}
  if #M.files == 0 then
    M.selected = 1
  elseif M.selected > #M.files then
    M.selected = #M.files
  end
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local lines = {}
  if #M.files == 0 then
    lines = { "No pending review." }
  else
    for index, file in ipairs(M.files) do
      local marker = index == M.selected and "> " or "  "
      table.insert(lines, marker .. status_label(file) .. " " .. file.path)
    end
  end

  set_modifiable(true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(M.buf, highlights.namespace, 0, -1)
  set_modifiable(false)

  for index, file in ipairs(M.files) do
    vim.api.nvim_buf_set_extmark(M.buf, highlights.namespace, index - 1, 0, {
      virt_text = { { " " .. badge(file), "CodexPending" } },
      virt_text_pos = "eol",
    })
  end
end

function M.select(index)
  if #M.files == 0 then
    M.selected = 1
    panes.show(nil)
    return
  end
  M.selected = math.max(1, math.min(index, #M.files))
  M.render(M.files)
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_cursor(M.win, { M.selected, 0 })
  end
  panes.show(M.files[M.selected])
end

function M.select_next(delta)
  M.select(M.selected + delta)
end

function M.current_file()
  local file = M.files[M.selected]
  return file and file.path or nil
end

function M.current_hunk()
  local file = M.files[M.selected]
  if not file or #(file.hunks or {}) == 0 then
    return nil
  end
  local hunk = panes.current_hunk()
  return hunk or 0
end

function M.buffer()
  return M.buf
end

function M.window()
  return M.win
end

function M.reset()
  M.buf = nil
  M.win = nil
  M.files = {}
  M.selected = 1
end

return M
