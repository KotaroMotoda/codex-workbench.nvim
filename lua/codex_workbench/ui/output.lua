local M = {
  buf = nil,
  win = nil,
  diff_preview = "",
  show_details = false,
}

local function ensure_window()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    return
  end
  vim.cmd("botright vertical 40new")
  M.win = vim.api.nvim_get_current_win()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "codex-workbench-output")
    vim.bo[M.buf].buftype = "nofile"
    vim.bo[M.buf].bufhidden = "hide"
    vim.bo[M.buf].swapfile = false
    vim.bo[M.buf].filetype = "markdown"
  end
  vim.api.nvim_win_set_buf(M.win, M.buf)
end

function M.open()
  ensure_window()
end

function M.append(text)
  ensure_window()
  if text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  local last = vim.api.nvim_buf_line_count(M.buf)
  vim.api.nvim_buf_set_lines(M.buf, last, last, false, lines)
end

function M.set_diff_preview(diff)
  M.diff_preview = diff
end

function M.handle_appserver_event(method, params)
  if method == "item/agentMessage/delta" then
    return
  end
  if M.show_details then
    M.append("\n```json\n" .. vim.json.encode({ method = method, params = params }) .. "\n```\n")
  end
end

function M.toggle_details()
  M.show_details = not M.show_details
end

return M

