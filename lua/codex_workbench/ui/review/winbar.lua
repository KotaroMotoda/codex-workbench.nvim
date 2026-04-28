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
  M.contexts[win] = context or {}
  if not enabled or not supports_winbar() then
    return
  end
  vim.wo[win].winbar = "%!v:lua.require('codex_workbench.ui.review.winbar').render()"
end

---@param win integer|nil
function M.clear(win)
  if win then
    M.contexts[win] = nil
    if supports_winbar() and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = ""
    end
  else
    M.contexts = {}
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
    return pane .. ": " .. path .. hunk
  end

  return key_hints()
end

return M
