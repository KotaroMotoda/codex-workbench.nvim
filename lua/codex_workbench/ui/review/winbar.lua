local M = {
  contexts = {},
}

local function supports_winbar()
  return vim.fn.has("nvim-0.8") == 1 and vim.fn.exists("+winbar") == 1
end

local function winid()
  return tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
end

local function width_for(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
  return vim.o.columns
end

local function statusline_escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

local function key(lhs)
  return "%#CodexWinbarKey#[" .. statusline_escape(lhs) .. "]%*"
end

local function value(text)
  return "%#CodexWinbarValue#" .. statusline_escape(text) .. "%*"
end

local function muted(text)
  return "%#CodexWinbarMuted#" .. statusline_escape(text) .. "%*"
end

local function key_hints()
  return key("a")
    .. "accept-all "
    .. key("r")
    .. "reject  "
    .. key("A")
    .. "file "
    .. key("R")
    .. "file  "
    .. key("h")
    .. "hunk "
    .. key("x")
    .. "reject  "
    .. key("]f")
    .. "next-file  "
    .. key("q")
    .. "quit"
end

---@param win integer
---@param context table
---@param enabled boolean
function M.apply(win, context, enabled)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not enabled or not supports_winbar() then
    -- Make sure we don't leave a stale winbar around when the caller
    -- opts out: clear both the cached context and the actual option.
    M.clear(win)
    return
  end
  M.contexts[win] = context or {}
  vim.wo[win].winbar = "%!v:lua.require('codex_workbench.ui.review.winbar').render()"
end

---@param win integer|nil
function M.clear(win)
  if win then
    M.contexts[win] = nil
    if supports_winbar() and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = ""
    end
    return
  end

  local known = M.contexts
  M.contexts = {}
  if not supports_winbar() then
    return
  end
  for w, _ in pairs(known) do
    if vim.api.nvim_win_is_valid(w) then
      vim.wo[w].winbar = ""
    end
  end
end

function M.render_context(context, win, width)
  context = context or {}
  width = width or width_for(win)
  if context.kind == "output" then
    return require("codex_workbench.ui.output_winbar").render({
      width = width,
      phase = context.phase,
      started_at = context.started_at,
    })
  end

  if context.kind == "review_tree" then
    if width < 80 then
      return "%#CodexWinbar#Review%*  " .. key("]f") .. "next-file  " .. key("q") .. "quit"
    end
    return "%#CodexWinbar#Review%*  " .. key_hints()
  end

  if context.kind == "review_pane" then
    local index = 0
    local count = tonumber(context.hunk_count) or 0
    local ok, panes = pcall(require, "codex_workbench.ui.review.panes")
    if ok then
      local current, total = panes.hunk_for_win(win)
      index = current or index
      count = total or count
    end
    local path = context.path or "(none)"
    local pane = context.pane or "pane"
    local hunk = count > 0 and ("hunk " .. index .. "/" .. count) or "no hunks"
    local badge = context.badge and (" " .. statusline_escape(context.badge)) or ""
    if width < 80 then
      return value(hunk) .. "%#CodexBadge#" .. badge .. "%*"
    end
    return muted(pane .. ": ") .. value(path) .. "%=" .. value(hunk) .. "%#CodexBadge#" .. badge .. "%*"
  end

  return key_hints()
end

function M.render()
  local win = winid()
  return M.render_context(M.contexts[win], win)
end

return M
