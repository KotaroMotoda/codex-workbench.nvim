local M = {
  buf = nil,
  win = nil,
  current = nil,
  opts = { layout = "vertical", winbar = true, signs = true },
}

---@param opts CodexWorkbenchReviewOpts|{}
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function parse_diff_path(line)
  local path = line:match("^diff %-%-git a/.+ b/(.+)$")
  if path then
    return path
  end
  return line:match('^diff %-%-git "a/.+" "b/(.+)"$')
end

local function set_modifiable(value)
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.bo[M.buf].modifiable = value
  end
end

local function ensure_window()
  local win_ok = M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
  local buf_ok = M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf)
  -- bufhidden=hide keeps M.buf valid even when another buffer is showing in
  -- the window, so also check that M.buf is actually attached to M.win.
  local attached = win_ok and buf_ok and vim.api.nvim_win_get_buf(M.win) == M.buf

  if attached then
    return
  end

  if not win_ok then
    if M.opts.layout == "horizontal" then
      vim.cmd("botright 18new")
    else
      vim.cmd("botright vertical 84new")
    end
    M.win = vim.api.nvim_get_current_win()
  end

  if not buf_ok then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "codex-workbench-review")
    vim.bo[M.buf].buftype = "nofile"
    vim.bo[M.buf].bufhidden = "hide"
    vim.bo[M.buf].swapfile = false
    vim.bo[M.buf].filetype = "diff"
    vim.bo[M.buf].modifiable = false
  end

  vim.api.nvim_win_set_buf(M.win, M.buf)
  if not win_ok then
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].wrap = false
  end
end

local function request_review_action(method, scope)
  local log = require("codex_workbench.log")
  local error_codes = require("codex_workbench.error_codes")
  local error_prompt = require("codex_workbench.ui.error_prompt")
  require("codex_workbench.ui.progress").set(method == "accept" and "Applying review" or "Rejecting review")
  require("codex_workbench.bridge").request(method, { scope = scope }, function(response)
    if response.ok then
      vim.cmd("checktime")
    else
      log.write("ERROR", "review_action_failed", response)
      vim.notify(
        error_codes.format(response) .. "\nLog: " .. log.path(),
        vim.log.levels.ERROR,
        { title = "codex-workbench" }
      )
      error_prompt.show(response)
    end
  end)
end

local function current_file()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  for lnum = cursor, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(M.buf, lnum - 1, lnum, false)[1] or ""
    local path = parse_diff_path(line)
    if path then
      return path, lnum
    end
  end
  return nil
end

local function current_hunk()
  local path, file_lnum = current_file()
  if not path then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = -1
  for lnum = file_lnum, cursor do
    local line = vim.api.nvim_buf_get_lines(M.buf, lnum - 1, lnum, false)[1] or ""
    if line:match("^@@ ") then
      hunk = hunk + 1
    end
  end
  if hunk < 0 then
    return nil
  end
  return path, hunk
end

function M.current_file()
  return current_file()
end

function M.current_hunk()
  return current_hunk()
end

local function map(lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = M.buf, silent = true, nowait = true })
end

local function set_keymaps()
  map("a", function()
    request_review_action("accept", "all")
  end)
  map("r", function()
    request_review_action("reject", "all")
  end)
  map("A", function()
    local path = current_file()
    request_review_action("accept", path and ("file:" .. path) or "all")
  end)
  map("R", function()
    local path = current_file()
    request_review_action("reject", path and ("file:" .. path) or "all")
  end)
  map("h", function()
    local path, hunk = current_hunk()
    if not path then
      vim.notify("No hunk under cursor", vim.log.levels.WARN, { title = "codex-workbench" })
      return
    end
    request_review_action("accept", "hunk:" .. path .. ":" .. hunk)
  end)
  map("x", function()
    local path, hunk = current_hunk()
    if not path then
      vim.notify("No hunk under cursor", vim.log.levels.WARN, { title = "codex-workbench" })
      return
    end
    request_review_action("reject", "hunk:" .. path .. ":" .. hunk)
  end)
  map("q", function()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
      vim.api.nvim_win_close(M.win, true)
    end
  end)
  map("]f", function()
    vim.fn.search("^diff --git ", "W")
  end)
  map("[f", function()
    vim.fn.search("^diff --git ", "bW")
  end)
end

local function apply_winbar()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    require("codex_workbench.ui.review.winbar").apply(M.win, { kind = "review_tree" }, M.opts.winbar ~= false)
  end
end

local function apply_diff_marks()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  local highlights = require("codex_workbench.ui.highlights")
  vim.api.nvim_buf_clear_namespace(M.buf, highlights.namespace, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(M.buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:match("^%+") and not line:match("^%+%+%+") then
      highlights.mark_line(M.buf, index - 1, "CodexAdd", "+", "CodexAddSign", M.opts.signs)
    elseif line:match("^%-") and not line:match("^%-%-%-") then
      highlights.mark_line(M.buf, index - 1, "CodexDelete", "-", "CodexDeleteSign", M.opts.signs)
    elseif line:match("^@@ ") then
      highlights.mark_line(M.buf, index - 1, "CodexChange", "~", "CodexChangeSign", M.opts.signs)
    end
  end
end

local function lines_for(item)
  if not item then
    return { "# Codex Review", "", "No pending review." }
  end
  local lines = {
    "# Codex Review",
    "",
    "id: " .. item.id,
    "turn: " .. item.turn_id,
    "status: " .. item.status,
    "",
    "files:",
  }
  for _, file in ipairs(item.files or {}) do
    local suffix = file.file_only and " [file]" or ""
    table.insert(lines, "  " .. file.path .. suffix)
  end
  table.insert(lines, "")
  for _, line in ipairs(vim.split(item.patch or "", "\n", { plain = true })) do
    table.insert(lines, line)
  end
  return lines
end

---@param item table|nil
function M.render(item)
  ensure_window()
  M.current = item
  set_modifiable(true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines_for(item))
  set_modifiable(false)
  set_keymaps()
  apply_winbar()
  apply_diff_marks()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_cursor(M.win, { math.min(9, vim.api.nvim_buf_line_count(M.buf)), 0 })
  end
end

---@param item table|nil
function M.open(item)
  M.render(item)
end

return M
