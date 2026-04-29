local parse = require("codex_workbench.ui.review.parse")
local render = require("codex_workbench.ui.inline.render")
local state = require("codex_workbench.ui.inline.state")
local keymap = require("codex_workbench.ui.inline.keymap")

local M = {
  opts = {
    enabled = true,
    prefix = "<leader>c",
    jump = { next = "]c", prev = "[c" },
    auto_show = true,
    fallback_to_review = true,
    fallback_threshold = 3,
  },
  current = nil,
}

---@param opts table|nil
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  keymap.configure({ prefix = M.opts.prefix, jump = M.opts.jump })
end

local function review()
  return require("codex_workbench.ui.review")
end

local function files_from_item(item)
  if item and item.files and #item.files > 0 then
    return item.files
  end
  return parse.parse(item and item.patch or "").files
end

local function usable_buf(buf)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if vim.bo[buf].modified then
    return false
  end
  return true
end

local function is_absolute(path)
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" then
    return true
  end
  if vim.fn.exists("*isabsolutepath") == 1 then
    return vim.fn.isabsolutepath(path) == 1
  end
  return false
end

local function resolve_path(path)
  if not path or path == "" then
    return nil
  end
  if is_absolute(path) then
    return vim.fn.fnamemodify(path, ":p")
  end
  return vim.fn.fnamemodify(vim.uv.cwd() .. "/" .. path, ":p")
end

local function can_show_file(file)
  return file and not file.binary and file.status ~= "D" and file.hunks and #file.hunks > 0
end

---@param item table|nil
---@return boolean
function M.should_inline(item)
  if not (M.opts.enabled and M.opts.auto_show) then
    return false
  end
  local files = files_from_item(item)
  if #files == 0 then
    return false
  end
  if M.opts.fallback_to_review and #files > (tonumber(M.opts.fallback_threshold) or 3) then
    return false
  end
  for _, file in ipairs(files) do
    if not can_show_file(file) then
      return false
    end
    local path = resolve_path(file.path)
    if not path or vim.fn.filereadable(path) ~= 1 then
      return false
    end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    if not usable_buf(buf) then
      return false
    end
  end
  return true
end

local function notify_fallback()
  vim.notify("Inline diff skipped; opening review buffer", vim.log.levels.INFO, { title = "codex-workbench" })
end

local function fallback(item, opts)
  if opts.fallback ~= false then
    notify_fallback()
    review().open(item)
  end
  return false
end

---@param item table|nil
---@param opts table|nil
function M.show(item, opts)
  opts = opts or {}
  M.clear()
  M.current = item
  local files = files_from_item(item)
  if #files == 0 then
    return fallback(item, opts)
  end
  for _, file in ipairs(files) do
    if not can_show_file(file) then
      return fallback(item, opts)
    end
    local path = resolve_path(file.path)
    if not path or vim.fn.filereadable(path) ~= 1 then
      return fallback(item, opts)
    end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    if not usable_buf(buf) then
      return fallback(item, opts)
    end
    state.set(buf, { path = file.path, hunks = file.hunks })
    render.apply(buf, file.hunks)
    keymap.attach(buf, M)
  end
  return true
end

---@param item table|nil
function M.handle_review(item)
  M.clear()
  M.current = item
  if M.should_inline(item) then
    M.show(item, { fallback = false })
  else
    review().open(item)
  end
end

local function report_response(response)
  if response and response.ok then
    vim.cmd("checktime")
    return true
  end
  local log = require("codex_workbench.log")
  local error_codes = require("codex_workbench.error_codes")
  local error_prompt = require("codex_workbench.ui.error_prompt")
  require("codex_workbench.ui.progress").done("Error", 0)
  log.write("ERROR", "inline_action_failed", response)
  vim.notify(
    error_codes.format(response) .. "\nLog: " .. log.path(),
    vim.log.levels.ERROR,
    { title = "codex-workbench" }
  )
  error_prompt.show(response)
  return false
end

local function request_action(method, scope, callback)
  require("codex_workbench.ui.progress").set(method == "accept" and "Applying inline hunk" or "Rejecting inline hunk")
  if method == "reject" then
    vim.notify(
      "Rejected inline changes require a new ask to restore",
      vim.log.levels.INFO,
      { title = "codex-workbench" }
    )
  end
  require("codex_workbench.bridge").request(method, { scope = scope }, function(response)
    if report_response(response) and callback then
      callback()
    end
  end)
end

local function ensure_unchanged(buf)
  local entry = state.get(buf)
  if not entry then
    return false
  end
  if vim.b[buf].changedtick ~= entry.changedtick or vim.bo[buf].modified then
    M.clear(buf)
    vim.notify("Buffer changed after review; opening review buffer", vim.log.levels.WARN, { title = "codex-workbench" })
    review().open(M.current)
    return false
  end
  return true
end

function M.on_buffer_changed(buf)
  if state.get(buf) then
    M.clear(buf)
    vim.notify("Buffer changed after review; inline diff cleared", vim.log.levels.WARN, { title = "codex-workbench" })
  else
    keymap.detach(buf)
  end
end

function M.accept_current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not ensure_unchanged(buf) then
    return
  end
  local entry = state.get(buf)
  local hunk, idx = state.current_hunk(buf)
  if not hunk then
    return
  end
  request_action("accept", ("hunk:%s:%d"):format(entry.path, hunk.index or (idx - 1)), function()
    render.clear(buf)
    state.remove_hunk(buf, idx)
    local rest = state.get(buf)
    if rest then
      render.apply(buf, rest.hunks)
    else
      keymap.detach(buf)
    end
  end)
end

function M.reject_current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not ensure_unchanged(buf) then
    return
  end
  local entry = state.get(buf)
  local hunk, idx = state.current_hunk(buf)
  if not (entry and hunk) then
    return
  end
  request_action("reject", ("hunk:%s:%d"):format(entry.path, hunk.index or (idx - 1)), function()
    render.clear(buf)
    state.remove_hunk(buf, idx)
    local rest = state.get(buf)
    if rest then
      render.apply(buf, rest.hunks)
    else
      keymap.detach(buf)
    end
  end)
end

function M.accept_file(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not ensure_unchanged(buf) then
    return
  end
  local entry = state.get(buf)
  if not entry then
    return
  end
  request_action("accept", "file:" .. entry.path, function()
    render.clear(buf)
    state.clear(buf)
    keymap.detach(buf)
  end)
end

function M.reject_file(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not ensure_unchanged(buf) then
    return
  end
  local entry = state.get(buf)
  if not entry then
    return
  end
  request_action("reject", "file:" .. entry.path, function()
    render.clear(buf)
    state.clear(buf)
    keymap.detach(buf)
  end)
end

function M.jump(buf, direction)
  buf = buf or vim.api.nvim_get_current_buf()
  local entry = state.get(buf)
  if not entry or #entry.hunks == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local target = entry.hunks[1]
  if direction > 0 then
    for _, hunk in ipairs(entry.hunks) do
      if (hunk.old_start or hunk.new_start or 1) > cursor then
        target = hunk
        break
      end
    end
  else
    for i = #entry.hunks, 1, -1 do
      local hunk = entry.hunks[i]
      if (hunk.old_start or hunk.new_start or 1) < cursor then
        target = hunk
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, { math.max(target.old_start or target.new_start or 1, 1), 0 })
end

function M.preview_current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local hunk = state.current_hunk(buf)
  if not hunk then
    return
  end
  local lines = { hunk.header or "@@ codex suggestion @@" }
  for _, line in ipairs(hunk.lines or {}) do
    table.insert(
      lines,
      line.raw or ((line.kind == "add" and "+" or line.kind == "delete" and "-" or " ") .. (line.text or ""))
    )
  end
  local width = math.max(40, math.min(100, vim.o.columns - 8))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.5)))
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = "diff"
  vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Codex inline hunk ",
  })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = float_buf, silent = true })
end

function M.open_review()
  review().open(M.current)
end

function M.clear(buf)
  if buf then
    if vim.api.nvim_buf_is_valid(buf) then
      render.clear(buf)
    end
    state.clear(buf)
    keymap.detach(buf)
    return
  end
  for candidate in pairs(state.by_buf) do
    M.clear(candidate)
  end
  state.reset()
end

function M._reset_for_tests()
  M.current = nil
  M.configure({})
  M.clear()
  keymap.reset()
end

return M
