local M = {
  buf = nil,
  win = nil,
  opts = { position = "right", size = 40, winbar = true },
  diff_preview = "",
  show_details = false,
  final_text = "",
  streamed_text = "",
  phase = "idle",
  turn_started_at = nil,
}

local winbar_group = vim.api.nvim_create_augroup("CodexWorkbenchOutputWinbar", { clear = false })

---@param opts CodexWorkbenchOutputOpts|{}
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function set_modifiable(value)
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.bo[M.buf].modifiable = value
  end
end

local function clear_winbar(win)
  require("codex_workbench.ui.review.winbar").clear(win)
end

local function track_winbar_cleanup(win)
  pcall(vim.api.nvim_clear_autocmds, { group = winbar_group, pattern = tostring(win) })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = winbar_group,
    pattern = tostring(win),
    once = true,
    callback = function(args)
      clear_winbar(tonumber(args.match))
    end,
  })
end

local function ensure_window()
  local win_ok = M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
  local buf_ok = M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf)
  -- bufhidden=hide keeps M.buf valid even when the window shows another buffer,
  -- so also verify the buffer is actually attached to the window.
  local attached = win_ok and buf_ok and vim.api.nvim_win_get_buf(M.win) == M.buf

  if attached then
    return
  end

  if not win_ok then
    local size = tonumber(M.opts.size) or 40
    if M.opts.position == "bottom" then
      vim.cmd("botright " .. size .. "new")
    else
      vim.cmd("botright vertical " .. size .. "new")
    end
    M.win = vim.api.nvim_get_current_win()
  end

  if not buf_ok then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "codex-workbench-output")
    vim.bo[M.buf].buftype = "nofile"
    vim.bo[M.buf].bufhidden = "hide"
    vim.bo[M.buf].swapfile = false
    vim.bo[M.buf].filetype = "markdown"
    vim.bo[M.buf].modifiable = false
  end

  vim.api.nvim_win_set_buf(M.win, M.buf)
  if not win_ok then
    vim.wo[M.win].wrap = true
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
  end
  require("codex_workbench.ui.review.winbar").apply(M.win, {
    kind = "output",
    phase = M.phase,
    started_at = M.turn_started_at,
  }, M.opts.winbar ~= false)
  track_winbar_cleanup(M.win)
  vim.keymap.set("n", "q", function()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
      clear_winbar(M.win)
      vim.api.nvim_win_close(M.win, true)
    end
  end, { buffer = M.buf, silent = true, nowait = true })
  vim.keymap.set("n", "<C-\\>", function()
    M.toggle_details()
  end, { buffer = M.buf, silent = true, nowait = true })
end

local function set_lines(lines)
  ensure_window()
  set_modifiable(true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  set_modifiable(false)
end

local function append_to_last(text)
  ensure_window()
  if text == "" then
    return
  end
  set_modifiable(true)
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  if line_count == 0 then
    vim.api.nvim_buf_set_lines(M.buf, 0, 0, false, { "" })
    line_count = 1
  end
  local lines = vim.split(text, "\n", { plain = true })
  local last = vim.api.nvim_buf_get_lines(M.buf, line_count - 1, line_count, false)[1] or ""
  lines[1] = last .. lines[1]
  vim.api.nvim_buf_set_lines(M.buf, line_count - 1, line_count, false, lines)
  set_modifiable(false)
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_cursor(M.win, { vim.api.nvim_buf_line_count(M.buf), 0 })
  end
end

function M.open()
  ensure_window()
end

local function redraw_winbar()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    require("codex_workbench.ui.review.winbar").apply(M.win, {
      kind = "output",
      phase = M.phase,
      started_at = M.turn_started_at,
    }, M.opts.winbar ~= false)
    vim.cmd("redrawstatus")
  end
end

function M.start_turn()
  M.final_text = ""
  M.streamed_text = ""
  M.phase = "streaming"
  M.turn_started_at = os.time()
  set_lines({ "# Codex", "", "" })
  redraw_winbar()
end

function M.finish_turn()
  M.phase = "ready"
  append_to_last("\n")
  redraw_winbar()
end

---@param message string
function M.show_error(message)
  M.phase = "error"
  set_lines({
    "# Codex",
    "",
    "Error",
    "",
    message,
    "",
    "Details were written to:",
    require("codex_workbench.log").path(),
  })
  redraw_winbar()
end

---@param text string
function M.append(text)
  M.streamed_text = M.streamed_text .. text
  append_to_last(text)
end

---@param text string
function M.set_final(text)
  if text == "" or text == M.final_text then
    return
  end
  M.final_text = text
  if M.streamed_text == "" then
    M.append(text)
    return
  end
  if vim.startswith(text, M.streamed_text) then
    local suffix = text:sub(#M.streamed_text + 1)
    if suffix ~= "" then
      M.append(suffix)
    end
    return
  end
  if not vim.startswith(M.streamed_text, text) then
    M.append("\n\n--- final ---\n\n" .. text)
  end
end

---@param diff string
function M.set_diff_preview(diff)
  M.diff_preview = diff
end

---@param method string
---@param params any
function M.handle_appserver_event(method, params)
  if method == "item/agentMessage/delta" then
    return
  end
  if M.show_details then
    append_to_last("\n`" .. method .. "` " .. vim.inspect(params) .. "\n")
  end
end

function M.toggle_details()
  M.show_details = not M.show_details
  vim.notify("Codex detail stream: " .. (M.show_details and "on" or "off"), vim.log.levels.INFO, {
    title = "codex-workbench",
  })
end

return M
