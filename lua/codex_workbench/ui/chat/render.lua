local M = {}

local function set_modifiable(buf, value)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = value
  end
end

local function append_lines(buf, lines)
  set_modifiable(buf, true)
  local start = vim.api.nvim_buf_line_count(buf)
  if start == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    start = 0
  end
  vim.api.nvim_buf_set_lines(buf, start, start, false, lines)
  set_modifiable(buf, false)
end

local function append_to_last(buf, text)
  if text == "" then
    return
  end
  set_modifiable(buf, true)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "" })
    line_count = 1
  end
  local lines = vim.split(text, "\n", { plain = true })
  local last = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
  lines[1] = last .. lines[1]
  vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, lines)
  set_modifiable(buf, false)
end

function M.render_messages(buf, messages)
  local lines = {}
  for _, message in ipairs(messages or {}) do
    local role = message.role or message.type or "message"
    local text = message.text or message.content or message.message or ""
    table.insert(lines, "### " .. role)
    table.insert(lines, "")
    for _, line in ipairs(vim.split(tostring(text), "\n", { plain = true })) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end
  if #lines == 0 then
    lines = { "# Codex Chat", "", "_No messages yet._" }
  end
  set_modifiable(buf, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  set_modifiable(buf, false)
end

function M.append_user(buf, text)
  append_lines(buf, { "", "### you", "" })
  append_to_last(buf, text)
  append_lines(buf, { "" })
end

function M.start_assistant(buf)
  append_lines(buf, { "", "### codex", "" })
end

function M.append_delta(buf, text)
  append_to_last(buf, text)
end

function M.set_final(buf, final_text, streamed_text)
  if final_text == "" then
    return streamed_text
  end
  streamed_text = streamed_text or ""
  if streamed_text == "" then
    M.append_delta(buf, final_text)
    return final_text
  end
  if vim.startswith(final_text, streamed_text) then
    local suffix = final_text:sub(#streamed_text + 1)
    if suffix ~= "" then
      M.append_delta(buf, suffix)
    end
    return final_text
  end
  if not vim.startswith(streamed_text, final_text) then
    M.append_delta(buf, "\n\n--- final ---\n\n" .. final_text)
    return streamed_text .. "\n\n--- final ---\n\n" .. final_text
  end
  return streamed_text
end

return M
