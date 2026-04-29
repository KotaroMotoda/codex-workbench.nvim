local highlights = require("codex_workbench.ui.review.highlights")
local winbar = require("codex_workbench.ui.review.winbar")

local M = {
  before_buf = nil,
  after_buf = nil,
  before_win = nil,
  after_win = nil,
  current = nil,
  opts = { winbar = true },
  line_hunks = {},
  hunk_start_lines = {},
  last_hunk = nil,
}

local cursor_group = vim.api.nvim_create_augroup("CodexWorkbenchReviewPanes", { clear = false })

local function set_modifiable(buf, value)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = value
  end
end

local function create_buffer(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name .. "-" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

local function remember_hunk_for_win(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if buf ~= M.before_buf and buf ~= M.after_buf then
    return
  end
  local map = M.line_hunks[buf]
  if not map then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local index = map[lnum]
  if index ~= nil then
    M.last_hunk = index
  end
end

local function track_pane_cursor(buf, win)
  pcall(vim.api.nvim_clear_autocmds, { group = cursor_group, buffer = buf })
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI", "WinEnter" }, {
    group = cursor_group,
    buffer = buf,
    callback = function()
      remember_hunk_for_win(win)
    end,
  })
end

---@param opts table|nil
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

---@param before_win integer
---@param after_win integer
function M.attach(before_win, after_win)
  M.before_win = before_win
  M.after_win = after_win
  if not M.before_buf or not vim.api.nvim_buf_is_valid(M.before_buf) then
    M.before_buf = create_buffer("codex-workbench-review-before")
  end
  if not M.after_buf or not vim.api.nvim_buf_is_valid(M.after_buf) then
    M.after_buf = create_buffer("codex-workbench-review-after")
  end
  vim.api.nvim_win_set_buf(before_win, M.before_buf)
  vim.api.nvim_win_set_buf(after_win, M.after_buf)
  vim.wo[before_win].wrap = false
  vim.wo[after_win].wrap = false
  vim.wo[before_win].number = true
  vim.wo[after_win].number = true
  vim.wo[before_win].relativenumber = false
  vim.wo[after_win].relativenumber = false
  track_pane_cursor(M.before_buf, before_win)
  track_pane_cursor(M.after_buf, after_win)
end

local function set_filetype(buf, path)
  if not path or not vim.filetype or not vim.filetype.match then
    return
  end
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].filetype = ft
  end
end

local function push_line(lines, hunk_map, hunk_starts, line, hunk_index)
  table.insert(lines, line)
  hunk_map[#lines] = hunk_index
  if hunk_starts and hunk_starts[hunk_index] == nil then
    hunk_starts[hunk_index] = #lines
  end
end

local function render_file(file)
  local before_lines, after_lines = {}, {}
  local before_marks, after_marks = {}, {}
  local before_hunks, after_hunks = {}, {}
  local before_hunk_starts, after_hunk_starts = {}, {}
  local hunk_count = #(file.hunks or {})

  if file.binary then
    push_line(before_lines, before_hunks, before_hunk_starts, "[binary] " .. (file.old_path or file.path), 0)
    push_line(after_lines, after_hunks, after_hunk_starts, "[binary] " .. (file.new_path or file.path), 0)
    return before_lines,
      after_lines,
      before_marks,
      after_marks,
      before_hunks,
      after_hunks,
      before_hunk_starts,
      after_hunk_starts
  end

  if hunk_count == 0 then
    push_line(before_lines, before_hunks, before_hunk_starts, "(no textual diff)", 0)
    push_line(after_lines, after_hunks, after_hunk_starts, "(no textual diff)", 0)
    return before_lines,
      after_lines,
      before_marks,
      after_marks,
      before_hunks,
      after_hunks,
      before_hunk_starts,
      after_hunk_starts
  end

  for index, hunk in ipairs(file.hunks or {}) do
    local hunk_index = index - 1
    push_line(before_lines, before_hunks, before_hunk_starts, hunk.header, hunk_index)
    push_line(after_lines, after_hunks, after_hunk_starts, hunk.header, hunk_index)
    table.insert(before_marks, { row = #before_lines - 1, group = "CodexChange", sign = "~" })
    table.insert(after_marks, { row = #after_lines - 1, group = "CodexChange", sign = "~" })

    for _, line in ipairs(hunk.lines or {}) do
      if line.kind == "context" then
        push_line(before_lines, before_hunks, nil, line.text, hunk_index)
        push_line(after_lines, after_hunks, nil, line.text, hunk_index)
      elseif line.kind == "delete" then
        push_line(before_lines, before_hunks, nil, line.text, hunk_index)
        push_line(after_lines, after_hunks, nil, "", hunk_index)
        table.insert(before_marks, { row = #before_lines - 1, group = "CodexDelete", sign = "-" })
      elseif line.kind == "add" then
        push_line(before_lines, before_hunks, nil, "", hunk_index)
        push_line(after_lines, after_hunks, nil, line.text, hunk_index)
        table.insert(after_marks, { row = #after_lines - 1, group = "CodexAdd", sign = "+" })
      else
        push_line(before_lines, before_hunks, nil, line.raw or line.text, hunk_index)
        push_line(after_lines, after_hunks, nil, line.raw or line.text, hunk_index)
      end
    end
  end

  return before_lines,
    after_lines,
    before_marks,
    after_marks,
    before_hunks,
    after_hunks,
    before_hunk_starts,
    after_hunk_starts
end

local function set_lines(buf, lines)
  set_modifiable(buf, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  set_modifiable(buf, false)
end

local function apply_marks(buf, marks)
  vim.api.nvim_buf_clear_namespace(buf, highlights.namespace, 0, -1)
  for _, mark in ipairs(marks) do
    highlights.mark_line(buf, mark.row, mark.group, mark.sign)
  end
end

---@param file table|nil
function M.show(file)
  if not M.before_buf or not M.after_buf then
    return
  end
  M.current = file
  if not file then
    set_lines(M.before_buf, { "No pending review." })
    set_lines(M.after_buf, { "No pending review." })
    M.line_hunks[M.before_buf] = nil
    M.line_hunks[M.after_buf] = nil
    M.hunk_start_lines[M.before_buf] = nil
    M.hunk_start_lines[M.after_buf] = nil
    M.last_hunk = nil
    vim.api.nvim_buf_clear_namespace(M.before_buf, highlights.namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(M.after_buf, highlights.namespace, 0, -1)
    -- Drop stale winbar contexts so the bar does not keep advertising
    -- a file that is no longer shown in the panes.
    if M.before_win then
      winbar.clear(M.before_win)
    end
    if M.after_win then
      winbar.clear(M.after_win)
    end
    return
  end

  local before_lines, after_lines, before_marks, after_marks, before_hunks, after_hunks, before_hunk_starts, after_hunk_starts =
    render_file(file)
  M.line_hunks[M.before_buf] = before_hunks
  M.line_hunks[M.after_buf] = after_hunks
  M.hunk_start_lines[M.before_buf] = before_hunk_starts
  M.hunk_start_lines[M.after_buf] = after_hunk_starts
  M.last_hunk = nil
  set_lines(M.before_buf, before_lines)
  set_lines(M.after_buf, after_lines)
  apply_marks(M.before_buf, before_marks)
  apply_marks(M.after_buf, after_marks)
  set_filetype(M.before_buf, file.old_path or file.path)
  set_filetype(M.after_buf, file.new_path or file.path)

  local context = {
    kind = "review_pane",
    path = file.path,
    hunk_count = #(file.hunks or {}),
  }
  winbar.apply(M.before_win, vim.tbl_extend("force", context, { pane = "before" }), M.opts.winbar ~= false)
  winbar.apply(M.after_win, vim.tbl_extend("force", context, { pane = "after" }), M.opts.winbar ~= false)
end

---@param win integer|nil
---@return integer|nil, integer|nil
function M.hunk_for_win(win)
  win = win or vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil, nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local map = M.line_hunks[buf]
  local count = M.current and #(M.current.hunks or {}) or 0
  if not map then
    return count > 0 and 1 or 0, count
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local index = map[lnum]
  if index == nil then
    return count > 0 and 1 or 0, count
  end
  remember_hunk_for_win(win)
  return index + 1, count
end

function M.current_hunk()
  local index = select(1, M.hunk_for_win(vim.api.nvim_get_current_win()))
  if not index or index == 0 then
    return nil
  end
  return index - 1
end

function M.buffers()
  return M.before_buf, M.after_buf
end

function M.last_focused_hunk()
  return M.last_hunk
end

function M.reset()
  M.before_buf = nil
  M.after_buf = nil
  M.before_win = nil
  M.after_win = nil
  M.current = nil
  M.line_hunks = {}
  M.hunk_start_lines = {}
  M.last_hunk = nil
  pcall(vim.api.nvim_clear_autocmds, { group = cursor_group })
end

---@param hunk_index integer|nil zero-based hunk index
function M.focus_hunk(hunk_index)
  if hunk_index == nil or not M.before_win or not vim.api.nvim_win_is_valid(M.before_win) then
    return
  end
  local before_starts = M.hunk_start_lines[M.before_buf] or {}
  local before_lnum = before_starts[hunk_index]
  if before_lnum then
    vim.api.nvim_win_set_cursor(M.before_win, { before_lnum, 0 })
  end
  if M.after_win and vim.api.nvim_win_is_valid(M.after_win) then
    local after_starts = M.hunk_start_lines[M.after_buf] or {}
    local after_lnum = after_starts[hunk_index]
    if after_lnum then
      vim.api.nvim_win_set_cursor(M.after_win, { after_lnum, 0 })
    end
  end
  M.last_hunk = hunk_index
end

return M
