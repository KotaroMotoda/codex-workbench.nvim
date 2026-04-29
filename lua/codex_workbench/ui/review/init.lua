local legacy = require("codex_workbench.ui.review.legacy")
local parse = require("codex_workbench.ui.review.parse")
local tree = require("codex_workbench.ui.review.tree")
local panes = require("codex_workbench.ui.review.panes")
local state = require("codex_workbench.ui.review.state")
local winbar = require("codex_workbench.ui.review.winbar")

local M = {
  opts = {
    layout = "vertical",
    mode = "split",
    tree_width = 30,
    pane_split = 50,
    ascii_only = false,
    winbar = true,
  },
  current = nil,
  buf = nil,
  win = nil,
  parsed = nil,
  tree_win = nil,
  before_win = nil,
  after_win = nil,
  state_item_key = nil,
}

---@param opts CodexWorkbenchReviewOpts|{}
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  legacy.configure(M.opts)
  tree.configure(M.opts)
  panes.configure(M.opts)
end

local function sync_legacy_state()
  M.buf = legacy.buf
  M.win = legacy.win
  M.current = legacy.current
end

local function request_review_action(method, scope, on_success)
  local log = require("codex_workbench.log")
  local error_codes = require("codex_workbench.error_codes")
  local error_prompt = require("codex_workbench.ui.error_prompt")
  local progress = require("codex_workbench.ui.progress")
  progress.set(method == "accept" and "Applying review" or "Rejecting review")
  require("codex_workbench.bridge").request(method, { scope = scope }, function(response)
    if response.ok then
      vim.cmd("checktime")
      if on_success then
        on_success(response)
      end
    else
      -- Stop the spinner immediately on failure; on success the bridge
      -- emits its own progress.done event.
      progress.done("Error", 0)
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

local function redraw_diffview_state()
  if M.opts.mode == "diffview" and M.parsed then
    tree.render(M.parsed.files)
    panes.show(M.parsed.files[tree.selected] or M.parsed.files[1])
  end
end

local function record_local_state(method, scope)
  if scope == "all" then
    for _, file in ipairs((M.parsed and M.parsed.files) or {}) do
      if method == "accept" then
        state.accept_file(file.path)
      else
        state.reject_file(file.path)
      end
    end
    return
  end
  local file_path = scope:match("^file:(.+)$")
  if file_path then
    if method == "accept" then
      state.accept_file(file_path)
    else
      state.reject_file(file_path)
    end
    return
  end
  local hunk_path, hunk = scope:match("^hunk:(.+):(%d+)$")
  if hunk_path then
    if method == "accept" then
      state.accept_hunk(hunk_path, tonumber(hunk))
    else
      state.reject_hunk(hunk_path, tonumber(hunk))
    end
  end
end

local function review_action(method, scope)
  request_review_action(method, scope, function()
    record_local_state(method, scope)
    redraw_diffview_state()
  end)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function ensure_layout()
  if valid_win(M.tree_win) and valid_win(M.before_win) and valid_win(M.after_win) then
    return
  end

  local tree_width = tonumber(M.opts.tree_width) or 30
  local ratio = math.max(10, math.min(90, tonumber(M.opts.pane_split) or 50))
  local content_width = math.max(60, vim.o.columns - tree_width)
  local before_width = math.max(30, math.floor(content_width * ratio / 100))
  local after_width = math.max(30, content_width - before_width)
  vim.cmd("botright vertical " .. after_width .. "new")
  M.after_win = vim.api.nvim_get_current_win()
  vim.cmd("leftabove vertical " .. before_width .. "new")
  M.before_win = vim.api.nvim_get_current_win()
  vim.cmd("leftabove vertical " .. tree_width .. "new")
  M.tree_win = vim.api.nvim_get_current_win()

  tree.attach(M.tree_win)
  panes.attach(M.before_win, M.after_win)
end

local function close_diffview()
  for _, win in ipairs({ M.tree_win, M.before_win, M.after_win }) do
    -- Drop winbar bookkeeping before closing so we never leak contexts
    -- for win ids that may later be reused by other windows.
    if win then
      winbar.clear(win)
    end
    if valid_win(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  M.tree_win = nil
  M.before_win = nil
  M.after_win = nil
end

local function current_file()
  if M.opts.mode == "diffview" then
    return tree.current_file()
  end
  if legacy.current_file then
    return legacy.current_file()
  end
  return nil
end

local function current_hunk()
  if M.opts.mode == "diffview" then
    local path = tree.current_file()
    local hunk = tree.current_hunk()
    if path and hunk ~= nil then
      return path, hunk
    end
    return nil
  end
  if legacy.current_hunk then
    return legacy.current_hunk()
  end
  return nil
end

local function set_common_keymaps(buf)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("a", function()
    review_action("accept", "all")
  end)
  map("r", function()
    review_action("reject", "all")
  end)
  map("A", function()
    local path = current_file()
    review_action("accept", path and ("file:" .. path) or "all")
  end)
  map("R", function()
    local path = current_file()
    review_action("reject", path and ("file:" .. path) or "all")
  end)
  map("h", function()
    local path, hunk = current_hunk()
    if not path then
      vim.notify("No hunk under cursor", vim.log.levels.WARN, { title = "codex-workbench" })
      return
    end
    review_action("accept", "hunk:" .. path .. ":" .. hunk)
  end)
  map("x", function()
    local path, hunk = current_hunk()
    if not path then
      vim.notify("No hunk under cursor", vim.log.levels.WARN, { title = "codex-workbench" })
      return
    end
    review_action("reject", "hunk:" .. path .. ":" .. hunk)
  end)
  map("q", close_diffview)
  map("]f", function()
    tree.select_next(1)
  end)
  map("[f", function()
    tree.select_next(-1)
  end)
  map("]h", function()
    tree.select_hunk_next(1)
  end)
  map("[h", function()
    tree.select_hunk_next(-1)
  end)
end

local function set_tree_keymaps()
  local buf = tree.buffer()
  if not buf then
    return
  end
  set_common_keymaps(buf)
  vim.keymap.set("n", "<CR>", function()
    tree.select(vim.api.nvim_win_get_cursor(0)[1])
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Tab>", function()
    tree.select_next(1)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<S-Tab>", function()
    tree.select_next(-1)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "j", function()
    tree.select_next(1)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "k", function()
    tree.select_next(-1)
  end, { buffer = buf, silent = true, nowait = true })
end

local function set_pane_keymaps()
  local before, after = panes.buffers()
  if before then
    set_common_keymaps(before)
  end
  if after then
    set_common_keymaps(after)
  end
end

local function render_diffview(item)
  ensure_layout()
  M.current = item
  local state_item_key = item and (item.id or item.turn_id or item.patch) or nil
  if state_item_key ~= M.state_item_key then
    state.reset()
    M.state_item_key = state_item_key
  end
  M.parsed = parse.parse(item and item.patch or "")
  tree.render(M.parsed.files)
  set_tree_keymaps()
  set_pane_keymaps()
  tree.select(#M.parsed.files > 0 and 1 or 0)
end

---@param item table|nil
function M.render(item)
  if M.opts.mode ~= "diffview" then
    legacy.configure(M.opts)
    legacy.render(item)
    sync_legacy_state()
    return
  end
  render_diffview(item)
end

---@param item table|nil
function M.open(item)
  M.render(item)
end

function M.current_file()
  return current_file()
end

function M.current_hunk()
  return current_hunk()
end

function M._reset_for_tests()
  close_diffview()
  tree.reset()
  panes.reset()
  M.current = nil
  M.buf = nil
  M.win = nil
  M.parsed = nil
  M.state_item_key = nil
end

return M
