local chat = require("codex_workbench.ui.chat")
local bridge = require("codex_workbench.bridge")
local context = require("codex_workbench.context")

describe("chat buffer", function()
  local original_request
  local original_snapshot
  local original_resolve

  before_each(function()
    original_request = bridge.request
    original_snapshot = context.snapshot
    original_resolve = context.resolve
    bridge.state.thread_id = "thread-1"
    bridge.state.phase = "ready"
    chat.configure({
      enabled = true,
      position = "right",
      width = 80,
      threads_width = 24,
      prompt_height = 4,
      enter_submits = true,
    })
    context.snapshot = function()
      return { file = "/tmp/a.lua", lnum = 1, lines = {}, selection = "" }
    end
    context.resolve = function(prompt)
      return "resolved:" .. prompt
    end
  end)

  after_each(function()
    chat.close()
    bridge.request = original_request
    context.snapshot = original_snapshot
    context.resolve = original_resolve
    bridge.state.thread_id = nil
  end)

  it("opens three chat buffers", function()
    bridge.request = function(method, _, cb)
      if method == "threads" then
        cb({ ok = true, result = { threads = {} } })
      elseif method == "thread/messages" then
        cb({ ok = true, result = { messages = {} } })
      end
    end

    chat.open()

    local buffer = require("codex_workbench.ui.chat.buffer")
    assert.is_true(vim.api.nvim_win_is_valid(buffer.threads_win))
    assert.is_true(vim.api.nvim_win_is_valid(buffer.messages_win))
    assert.is_true(vim.api.nvim_win_is_valid(buffer.prompt_win))
  end)

  it("submits prompt through bridge ask", function()
    local captured
    bridge.request = function(method, params, cb)
      if method == "ask" then
        captured = params
        cb({ ok = true, result = {} })
      elseif cb then
        cb({ ok = true, result = { messages = {}, threads = {} } })
      end
    end

    chat.open()
    chat.submit("hello @this")

    assert.equals("resolved:hello @this", captured.prompt)
    assert.equals("thread-1", captured.thread_id)
    assert.is_false(captured.new_thread)
    assert.is_true(captured.persist_history)
  end)

  it("appends streaming chunks to the messages buffer", function()
    bridge.request = function(_, _, cb)
      if cb then
        cb({ ok = true, result = { messages = {}, threads = {} } })
      end
    end
    chat.open()
    chat.handle_event("output_delta", { text = "hello" })
    chat.handle_event("output_delta", { text = " world" })

    local buffer = require("codex_workbench.ui.chat.buffer")
    local text = table.concat(vim.api.nvim_buf_get_lines(buffer.messages_buf, 0, -1, false), "\n")
    assert.is_true(text:find("hello world", 1, true) ~= nil)
  end)

  it("selects a thread from the sidebar", function()
    local resumed
    bridge.request = function(method, params, cb)
      if method == "threads" then
        cb({ ok = true, result = { threads = { { id = "t2", preview = "second" } } } })
      elseif method == "resume" then
        resumed = params.thread_id
        cb({ ok = true, result = { thread_id = params.thread_id } })
      elseif cb then
        cb({ ok = true, result = { messages = {} } })
      end
    end

    chat.open()
    chat.select_thread({ id = "t2" })

    assert.equals("t2", resumed)
  end)
end)
