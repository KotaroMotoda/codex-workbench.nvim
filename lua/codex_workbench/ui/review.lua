local M = {
  buf = nil,
  win = nil,
  current = nil,
}

local function ensure_window()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    return
  end
  vim.cmd("botright vertical 80new")
  M.win = vim.api.nvim_get_current_win()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "codex-workbench-review")
    vim.bo[M.buf].buftype = "nofile"
    vim.bo[M.buf].bufhidden = "hide"
    vim.bo[M.buf].swapfile = false
    vim.bo[M.buf].filetype = "diff"
  end
  vim.api.nvim_win_set_buf(M.win, M.buf)
end

local function lines_for(item)
  if not item then
    return { "No pending review." }
  end
  local lines = {
    "# codex-workbench review",
    "",
    "id: " .. item.id,
    "turn: " .. item.turn_id,
    "status: " .. item.status,
    "",
    "Files:",
  }
  for _, file in ipairs(item.files or {}) do
    local suffix = file.file_only and " [file-only]" or ""
    table.insert(lines, "- " .. file.path .. suffix)
  end
  table.insert(lines, "")
  table.insert(lines, item.patch or "")
  return lines
end

function M.render(item)
  ensure_window()
  M.current = item
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines_for(item))
end

function M.open(item)
  M.render(item)
end

return M

