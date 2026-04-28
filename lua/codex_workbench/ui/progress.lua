local M = {
  opts = {
    enabled = true,
    position = "bottom_right",
  },
  buf = nil,
  win = nil,
  timer = nil,
  close_timer = nil,
  text = "",
  frame = 1,
  frames = { "|", "/", "-", "\\" },
}

local uv = vim.uv or vim.loop

---@param opts table|nil
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function enabled()
  return M.opts.enabled ~= false and M.opts.position ~= "off"
end

local function close_timer(timer)
  if timer then
    timer:stop()
    timer:close()
  end
end

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "wipe"
  vim.bo[M.buf].swapfile = false
end

local function placement(width)
  local row
  if M.opts.position == "top_right" then
    row = 1
  else
    row = math.max(0, vim.o.lines - 3)
  end
  return {
    relative = "editor",
    row = row,
    col = math.max(0, vim.o.columns - width - 2),
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 60,
  }
end

local function render()
  if not enabled() or not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  local line = M.frames[M.frame] .. " " .. M.text
  local width = math.max(12, vim.fn.strdisplaywidth(line))
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_config(M.win, placement(width))
  else
    M.win = vim.api.nvim_open_win(M.buf, false, placement(width))
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { line })
  vim.bo[M.buf].modifiable = false
end

local function start_timer()
  if M.timer or not uv then
    return
  end
  M.timer = uv.new_timer()
  M.timer:start(80, 80, function()
    vim.schedule(function()
      M.frame = (M.frame % #M.frames) + 1
      render()
    end)
  end)
end

---@param text string
function M.set(text)
  if not enabled() then
    return
  end
  close_timer(M.close_timer)
  M.close_timer = nil
  M.text = text or ""
  ensure_buf()
  render()
  start_timer()
end

---@param text string|nil
---@param delay_ms integer|nil
function M.done(text, delay_ms)
  if text and text ~= "" then
    M.text = text
    render()
  end
  close_timer(M.timer)
  M.timer = nil
  delay_ms = delay_ms == nil and 1500 or delay_ms
  if delay_ms <= 0 then
    M.close()
    return
  end
  if uv then
    close_timer(M.close_timer)
    M.close_timer = uv.new_timer()
    M.close_timer:start(delay_ms, 0, function()
      vim.schedule(M.close)
    end)
  end
end

function M.close()
  close_timer(M.timer)
  close_timer(M.close_timer)
  M.timer = nil
  M.close_timer = nil
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

function M.window()
  return M.win
end

function M.reset()
  M.close()
  M.buf = nil
  M.text = ""
  M.frame = 1
end

return M
