local M = {
  contexts = {},
}

local function supports_winbar()
  return vim.fn.exists("+winbar") == 1
end

local function winid()
  return tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
end

local function key_hints()
  return "%#Keyword#[a]%* all-accept %#Keyword#[r]%* reject  %#Keyword#[A]%* file %#Keyword#[R]%* file  %#Keyword#[h]%* hunk %#Keyword#[x]%* reject  %#Keyword#[q]%* quit"
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

function M.render()
  local win = winid()
  local context = M.contexts[win] or {}
  if context.kind == "output" then
    return "Codex Output  %#Keyword#[<C-\\>]%* toggle-details  %#Keyword#[q]%* close"
  end

  if context.kind == "review_tree" then
    return "Review  " .. key_hints()
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
    local hunk = count > 0 and (" (hunk " .. index .. "/" .. count .. ")") or ""
    local badge = context.badge and (" " .. context.badge) or ""
    return "%#CodexWinbarMuted#"
      .. pane
      .. ":%* %#CodexWinbarValue#"
      .. path
      .. "%*"
      .. hunk
      .. "%#CodexBadge#"
      .. badge
      .. "%*"
  end

  return key_hints()
end

return M
