local legacy = require("codex_workbench.ui.review.legacy")
local parse = require("codex_workbench.ui.review.parse")
local tree = require("codex_workbench.ui.review.tree")
local panes = require("codex_workbench.ui.review.panes")
local winbar = require("codex_workbench.ui.review.winbar")

local M = {
  opts = {
    layout = "vertical",
    mode = "split",
    tree_width = 30,
    winbar = true,
  },
  current = nil,
  buf = nil,
  win = nil,
  parsed = nil,
  tree_win = nil,
  before_win = nil,
  after_win = nil,
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

local function request_review_action(method, scope)
  local log = require("codex_workbench.log")
  local error_prompt = require("codex_workbench.ui.error_prompt")
  local progress = require("codex_workbench.ui.progress")
  progress.set(method == "accept" and "Applying review" or "Rejecting review")
  require("codex_workbench.bridge").request(method, { scope = scope }, function(response)
    if response.ok then
      vim.cmd("checktime")
    else
      -- Stop the spinner immediately on failure; on success the bridge
      -- emits its own progress.done event.
      progress.done("Error", 0)
      log.write("ERROR", "review_action_failed", response)
      error_prompt.show(response)
    end
  end)
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function ensure_layout()
  if valid_win(M.tree_win) and valid_win(M.before_win) and valid_win(M.after_win) then
    return
  end

  local after_width = math.max(30, math.floor((vim.o.columns - (tonumber(M.opts.tree_width) or 30)) / 2))
  vim.cmd("botright vertical " .. after_width .. "new")
  M.after_win = vim.api.nvim_get_current_win()
  vim.cmd("leftabove vertical " .. after_width .. "new")
  M.before_win = vim.api.nvim_get_current_win()
  vim.cmd("leftabove vertical " .. (tonumber(M.opts.tree_width) or 30) .. "new")
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
  map("q", close_diffview)
  map("]f", function()
    tree.select_next(1)
  end)
  map("[f", function()
    tree.select_next(-1)
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

function M.reopen()
  M.render(M.current)
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
end

return M
