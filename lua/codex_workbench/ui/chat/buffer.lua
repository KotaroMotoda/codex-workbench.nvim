local render = require("codex_workbench.ui.chat.render")

local M = {
  opts = {},
  threads_buf = nil,
  messages_buf = nil,
  prompt_buf = nil,
  threads_win = nil,
  messages_win = nil,
  prompt_win = nil,
  thread_items = {},
}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function scratch(name, filetype, modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = modifiable
  return buf
end

local function ensure_bufs()
  if not valid_buf(M.threads_buf) then
    M.threads_buf = scratch("codex-workbench-chat-threads", "codex-workbench-threads", false)
  end
  if not valid_buf(M.messages_buf) then
    M.messages_buf = scratch("codex-workbench-chat-messages", "markdown", false)
  end
  if not valid_buf(M.prompt_buf) then
    M.prompt_buf = scratch("codex-workbench-chat-prompt", "markdown", true)
  end
end

local function set_win_options(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true
  vim.wo[win].signcolumn = "no"
end

function M.configure(opts)
  M.opts = opts or {}
end

function M.is_open()
  return valid_win(M.threads_win) and valid_win(M.messages_win) and valid_win(M.prompt_win)
end

function M.open()
  ensure_bufs()
  if M.is_open() then
    vim.api.nvim_set_current_win(M.prompt_win)
    return
  end

  if M.opts.position == "tab" then
    vim.cmd("tabnew")
  else
    vim.cmd("botright vertical " .. (tonumber(M.opts.width) or 100) .. "new")
  end
  M.threads_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(M.threads_win, tonumber(M.opts.threads_width) or 30)
  vim.api.nvim_win_set_buf(M.threads_win, M.threads_buf)
  set_win_options(M.threads_win)

  vim.cmd("rightbelow vertical new")
  M.messages_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.messages_win, M.messages_buf)
  set_win_options(M.messages_win)

  vim.cmd("belowright " .. (tonumber(M.opts.prompt_height) or 5) .. "new")
  M.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(M.prompt_win, tonumber(M.opts.prompt_height) or 5)
  vim.api.nvim_win_set_buf(M.prompt_win, M.prompt_buf)
  set_win_options(M.prompt_win)

  vim.api.nvim_set_current_win(M.prompt_win)
  vim.cmd("startinsert")
end

function M.close()
  for _, win in ipairs({ M.prompt_win, M.messages_win, M.threads_win }) do
    if valid_win(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
end

local function set_buf_lines(buf, lines, modifiable)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
end

function M.render_threads(payload, active_thread_id)
  ensure_bufs()
  M.thread_items = require("codex_workbench.ui.thread_picker").sidebar_items(payload)
  local lines = { "Threads", "" }
  for _, item in ipairs(M.thread_items) do
    if item.new_thread then
      table.insert(lines, "+ New thread")
    else
      local id = item.id or ""
      local title = item.name or item.preview or id
      local marker = id == active_thread_id and "* " or "  "
      table.insert(lines, marker .. title)
    end
  end
  set_buf_lines(M.threads_buf, lines, false)
end

function M.thread_at_cursor()
  if not valid_win(M.threads_win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(M.threads_win)[1]
  return M.thread_items[lnum - 2]
end

function M.render_messages(messages)
  ensure_bufs()
  render.render_messages(M.messages_buf, messages)
end

function M.prompt_text()
  ensure_bufs()
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false), "\n"))
end

function M.clear_prompt()
  ensure_bufs()
  set_buf_lines(M.prompt_buf, { "" }, true)
end

return M
