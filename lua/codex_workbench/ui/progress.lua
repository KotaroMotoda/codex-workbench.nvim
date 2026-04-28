local uv = vim.uv or vim.loop

local unicode_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ascii_frames = { "|", "/", "-", "\\" }
local namespace = vim.api.nvim_create_namespace("codex_workbench/progress")

local M = {
  opts = {
    enabled = true,
    position = "bottom_right",
    ascii_only = false,
    fade_ms = 1500,
  },
  win = nil,
  buf = nil,
  timer = nil,
  close_timer = nil,
  state = {
    label = "",
    spinner_idx = 1,
    started_at = nil,
    finished_at = nil,
    static = false,
    hl = nil,
    closed = true,
  },
}

---@param opts table|nil
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function enabled()
  return M.opts.enabled ~= false and M.opts.position ~= "off"
end

local function schedule(fn)
  vim.schedule(function()
    pcall(fn)
  end)
end

local function close_timer(timer)
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
end

local function frames()
  return M.opts.ascii_only and ascii_frames or unicode_frames
end

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return true
  end

  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  return true
end

---@param width integer
---@param opening boolean|nil
---@return table
local function placement(width, opening)
  local row
  if M.opts.position == "top_right" then
    row = vim.o.showtabline > 0 and 1 or 0
  else
    row = math.max(0, vim.o.lines - 3)
  end

  local config = {
    relative = "editor",
    row = row,
    col = math.max(0, vim.o.columns - width - 2),
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    border = "none",
    zindex = 50,
  }
  if opening then
    config.noautocmd = true
  end
  return config
end

local function current_line()
  local prefix
  if M.state.hl == "CodexPending" then
    prefix = "✗ "
  elseif M.state.finished_at then
    prefix = "✓ "
  elseif M.state.static then
    prefix = "  "
  else
    local spinner = frames()
    prefix = spinner[M.state.spinner_idx] .. " "
  end
  return prefix .. (M.state.label or "")
end

local function render()
  if M.state.closed or not enabled() or not ensure_buf() then
    return
  end

  local line = current_line()
  local width = math.min(60, math.max(20, vim.fn.strdisplaywidth(line) + 2))

  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_config(M.win, placement(width, false))
  else
    M.win = vim.api.nvim_open_win(M.buf, false, placement(width, true))
  end

  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { line })
  vim.api.nvim_buf_clear_namespace(M.buf, namespace, 0, -1)
  if M.state.hl then
    pcall(vim.api.nvim_buf_add_highlight, M.buf, namespace, M.state.hl, 0, 0, -1)
  end
  vim.bo[M.buf].modifiable = false
end

local function stop_spinner()
  close_timer(M.timer)
  M.timer = nil
end

local function start_spinner()
  if M.state.static or M.timer or not uv then
    return
  end

  M.timer = uv.new_timer()
  M.timer:start(0, 80, function()
    schedule(function()
      local spinner = frames()
      M.state.spinner_idx = (M.state.spinner_idx % #spinner) + 1
      render()
    end)
  end)
end

local function parse_label_opts(label, opts)
  if type(label) == "table" then
    return label.label, label
  end
  return label, opts or {}
end

---@param label string
---@param opts table|nil
function M.set(label, opts)
  label, opts = parse_label_opts(label, opts)
  schedule(function()
    if not enabled() then
      M.close()
      return
    end

    close_timer(M.close_timer)
    M.close_timer = nil
    M.state.label = label or ""
    M.state.closed = false
    M.state.static = opts.static == true
    M.state.hl = opts.hl
    M.state.finished_at = nil
    M.state.started_at = M.state.started_at or uv and uv.hrtime() or vim.loop.hrtime()

    if M.state.static then
      stop_spinner()
    else
      start_spinner()
    end
    render()
  end)
end

---@param label_or_opts string|table|nil
---@param delay_ms integer|nil
function M.done(label_or_opts, delay_ms)
  local label, opts = parse_label_opts(label_or_opts, type(delay_ms) == "table" and delay_ms or nil)
  schedule(function()
    if label and label ~= "" then
      M.state.label = label
    end
    M.state.closed = false
    M.state.static = true
    M.state.hl = opts.hl or "CodexAccepted"
    M.state.finished_at = uv and uv.hrtime() or vim.loop.hrtime()
    stop_spinner()
    render()

    local fade_ms = opts.fade_ms or delay_ms
    fade_ms = fade_ms == nil and M.opts.fade_ms or fade_ms
    if fade_ms <= 0 then
      M.close()
      return
    end

    if uv then
      close_timer(M.close_timer)
      M.close_timer = uv.new_timer()
      M.close_timer:start(fade_ms, 0, function()
        schedule(M.close)
      end)
    end
  end)
end

---@param message string|nil
function M.error(message)
  M.done({ label = message or "Error", hl = "CodexPending", fade_ms = M.opts.fade_ms })
end

function M.reposition()
  schedule(function()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
      render()
    end
  end)
end

function M.close()
  M.state.closed = true
  stop_spinner()
  close_timer(M.close_timer)
  M.close_timer = nil

  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

function M.window()
  return M.win
end

function M.buffer()
  return M.buf
end

function M.reset()
  M.close()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
  end
  M.buf = nil
  M.state = {
    label = "",
    spinner_idx = 1,
    started_at = nil,
    finished_at = nil,
    static = false,
    hl = nil,
    closed = true,
  }
  M.opts = {
    enabled = true,
    position = "bottom_right",
    ascii_only = false,
    fade_ms = 1500,
  }
end

return M
