local buffer = require("codex_workbench.ui.chat.buffer")
local history = require("codex_workbench.ui.chat.history")
local render = require("codex_workbench.ui.chat.render")

local M = {
  opts = {},
  current_thread_id = nil,
  streamed_text = "",
  final_text = "",
}

function M.configure(opts)
  M.opts = opts or {}
  buffer.configure(M.opts)
end

local function report_error(response)
  if response and response.ok == false then
    vim.notify(response.error or response.error_code or "Codex chat request failed", vim.log.levels.ERROR, {
      title = "codex-workbench",
    })
    return true
  end
  return false
end

function M.attach_thread(thread_id)
  M.current_thread_id = thread_id
  local bridge = require("codex_workbench.bridge")
  history.load(bridge, thread_id, function(messages)
    buffer.render_messages(messages)
  end)
end

function M.refresh_threads()
  local bridge = require("codex_workbench.bridge")
  bridge.request("threads", {}, function(response)
    if report_error(response) then
      return
    end
    buffer.render_threads(response.result or {}, M.current_thread_id or bridge.state.thread_id)
  end)
end

function M.select_thread(item)
  if not item then
    return
  end
  local bridge = require("codex_workbench.bridge")
  if item.new_thread then
    M.current_thread_id = nil
    bridge.state.thread_id = nil
    bridge.state.phase = "ready"
    buffer.render_messages({})
    M.refresh_threads()
    return
  end
  local thread_id = item.id or item.thread_id
  if not thread_id then
    return
  end
  bridge.request("resume", { thread_id = thread_id }, function(response)
    if report_error(response) then
      return
    end
    local result = response.result or {}
    M.attach_thread(result.thread_id or thread_id)
    M.refresh_threads()
  end)
end

function M.delete_thread(item)
  if not item or item.new_thread then
    return
  end
  local thread_id = item.id or item.thread_id
  if not thread_id then
    return
  end
  if vim.fn.confirm("Delete Codex thread " .. thread_id .. "?", "&Delete\n&Cancel", 2) ~= 1 then
    return
  end
  local bridge = require("codex_workbench.bridge")
  bridge.request("thread/delete", { thread_id = thread_id }, function(response)
    if report_error(response) then
      return
    end
    if M.current_thread_id == thread_id then
      M.current_thread_id = nil
      buffer.render_messages({})
    end
    M.refresh_threads()
  end)
end

function M.open()
  if M.opts.enabled == false then
    return
  end
  buffer.open()
  require("codex_workbench.ui.chat.prompt").attach(M, buffer.prompt_buf, M.opts)
  vim.keymap.set("n", "<CR>", function()
    M.select_thread(buffer.thread_at_cursor())
  end, { buffer = buffer.threads_buf, silent = true, nowait = true })
  vim.keymap.set("n", "dd", function()
    M.delete_thread(buffer.thread_at_cursor())
  end, { buffer = buffer.threads_buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buffer.messages_buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buffer.threads_buf, silent = true, nowait = true })
  M.refresh_threads()
  M.attach_thread(M.current_thread_id or require("codex_workbench.bridge").state.thread_id)
end

function M.close()
  buffer.close()
end

function M.clear()
  buffer.clear_prompt()
end

function M.cancel()
  vim.cmd("stopinsert")
end

function M.submit(text)
  local prompt = vim.trim(text or buffer.prompt_text())
  if prompt == "" then
    return
  end
  local opts = require("codex_workbench").opts or require("codex_workbench.config").setup({})
  local snap = require("codex_workbench.context").snapshot()
  local resolved = require("codex_workbench.context").resolve(prompt, opts, snap)
  local bridge = require("codex_workbench.bridge")

  buffer.clear_prompt()
  render.append_user(buffer.messages_buf, prompt)
  render.start_assistant(buffer.messages_buf)
  M.streamed_text = ""
  M.final_text = ""
  require("codex_workbench.ui.progress").set("Asking")
  bridge.request("ask", {
    prompt = resolved,
    thread_id = M.current_thread_id or bridge.state.thread_id,
    new_thread = not (M.current_thread_id or bridge.state.thread_id),
  }, function(response)
    if not report_error(response) then
      M.current_thread_id = bridge.state.thread_id or M.current_thread_id
      M.refresh_threads()
    end
  end)
end

function M.handle_event(event, payload)
  if not buffer.is_open() then
    return
  end
  if event == "turn_started" then
    M.current_thread_id = payload.thread_id or M.current_thread_id
  elseif event == "thread_started" then
    M.current_thread_id = payload.thread_id or M.current_thread_id
  elseif event == "output_delta" then
    local text = payload.text or ""
    M.streamed_text = M.streamed_text .. text
    render.append_delta(buffer.messages_buf, text)
  elseif event == "message_completed" then
    M.final_text = payload.text or ""
    M.streamed_text = render.set_final(buffer.messages_buf, M.final_text, M.streamed_text)
  elseif event == "turn_completed" then
    render.append_delta(buffer.messages_buf, "\n")
    M.refresh_threads()
  elseif event == "turn_error" then
    render.append_delta(buffer.messages_buf, "\n\nError: " .. (payload.message or "Codex turn failed") .. "\n")
  end
end

return M
