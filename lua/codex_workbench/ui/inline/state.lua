local M = {
  by_buf = {},
}

local function normalize_hunks(hunks)
  local normalized = {}
  for index, hunk in ipairs(hunks or {}) do
    local copy = vim.deepcopy(hunk)
    copy.index = copy.index or (index - 1)
    table.insert(normalized, copy)
  end
  return normalized
end

---@param buf integer
---@param file table
function M.set(buf, file)
  M.by_buf[buf] = {
    path = file.path,
    hunks = normalize_hunks(file.hunks),
    changedtick = vim.b[buf].changedtick,
    active = true,
  }
end

---@param buf integer
---@return table|nil
function M.get(buf)
  return M.by_buf[buf]
end

---@param buf integer
---@return table|nil, integer|nil
function M.current_hunk(buf)
  local entry = M.get(buf)
  if not entry then
    return nil, nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local selected
  for idx, hunk in ipairs(entry.hunks) do
    local start_line = hunk.old_start or hunk.new_start or 1
    local count = math.max(hunk.old_count or 1, hunk.new_count or 1, 1)
    if cursor >= start_line and cursor <= start_line + count then
      return hunk, idx
    end
    if not selected or start_line <= cursor then
      selected = idx
    end
  end
  selected = selected or 1
  return entry.hunks[selected], selected
end

---@param buf integer
---@param hunk_index integer
function M.remove_hunk(buf, hunk_index)
  local entry = M.get(buf)
  if not entry then
    return
  end
  table.remove(entry.hunks, hunk_index)
  if #entry.hunks == 0 then
    M.clear(buf)
  end
end

---@param buf integer
function M.clear(buf)
  M.by_buf[buf] = nil
end

function M.reset()
  M.by_buf = {}
end

return M
