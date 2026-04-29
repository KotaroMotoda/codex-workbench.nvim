-- busted specs for codex_workbench.commands
local commands = require("codex_workbench.commands")
local bridge = require("codex_workbench.bridge")
local context = require("codex_workbench.context")
local output = require("codex_workbench.ui.output")

-- Minimal opts that satisfy commands.register.
local function make_opts()
  return {
    codex_cmd = "codex",
    binary = { auto_install = false },
    shadow = {
      root = "/tmp/cw-test",
      max_untracked_file_bytes = 5 * 1024 * 1024,
      max_untracked_total_bytes = 50 * 1024 * 1024,
    },
    ui = {
      output = { position = "right", size = 40 },
      review = { layout = "vertical" },
      inline = { enabled = true, auto_show = true },
      progress = { enabled = false },
      chat = { enabled = true, cmp_source = false },
    },
    errors = { interactive = false, show_log_path = false },
    contexts = {},
    session = { auto_resume = false },
  }
end

describe("commands", function()
  local original_initialize
  local original_request
  local original_context_snapshot
  local original_context_resolve
  local original_ui_select
  local original_ui_input
  local original_output_open
  local original_output_start_turn
  local captured_method
  local captured_params
  local request_calls

  before_each(function()
    original_initialize = bridge.initialize
    original_request = bridge.request
    original_context_snapshot = context.snapshot
    original_context_resolve = context.resolve
    original_ui_select = vim.ui.select
    original_ui_input = vim.ui.input
    original_output_open = output.open
    original_output_start_turn = output.start_turn
    captured_method = nil
    captured_params = nil
    request_calls = {}
    bridge.state.thread_id = nil
    bridge.state.phase = "idle"

    -- Stub bridge: initialize succeeds synchronously, request captures calls.
    bridge.initialize = function(_, cb)
      if cb then
        cb({ ok = true, result = {} })
      end
    end
    bridge.request = function(method, params, cb)
      captured_method = method
      captured_params = params
      table.insert(request_calls, { method = method, params = params })
      if cb then
        if method == "threads" then
          cb({
            ok = true,
            result = {
              project = { workspace = "/tmp/workspace", current_thread_id = bridge.state.thread_id or vim.NIL },
              threads = {
                {
                  id = "thread-99",
                  preview = "selected thread",
                  status = "notLoaded",
                  source = "cli",
                },
              },
            },
          })
        elseif method == "resume" then
          cb({ ok = true, result = { thread_id = params.thread_id } })
        else
          cb({ ok = true, result = {} })
        end
      end
    end
    output.open = function() end
    output.start_turn = function() end

    commands.register(make_opts())
  end)

  after_each(function()
    bridge.initialize = original_initialize
    bridge.request = original_request
    context.snapshot = original_context_snapshot
    context.resolve = original_context_resolve
    vim.ui.select = original_ui_select
    vim.ui.input = original_ui_input
    output.open = original_output_open
    output.start_turn = original_output_start_turn
    bridge.state.thread_id = nil
    bridge.state.phase = "idle"
  end)

  describe("registration", function()
    local expected_commands = {
      "CodexWorkbenchOpen",
      "CodexWorkbenchChat",
      "CodexWorkbenchAsk",
      "CodexWorkbenchReview",
      "CodexWorkbenchInline",
      "CodexWorkbenchThreads",
      "CodexWorkbenchAccept",
      "CodexWorkbenchReject",
      "CodexWorkbenchAbandon",
      "CodexWorkbenchResume",
      "CodexWorkbenchFork",
      "CodexWorkbenchStatus",
      "CodexWorkbenchToggleDetails",
      "CodexWorkbenchLogs",
      "CodexWorkbenchHealth",
      "CodexWorkbenchInstallBinary",
    }

    for _, name in ipairs(expected_commands) do
      it("registers " .. name, function()
        assert.equals(2, vim.fn.exists(":" .. name), name .. " should be registered")
      end)
    end
  end)

  describe("CodexWorkbenchAccept", function()
    it("sends accept with scope 'all' when called without arguments", function()
      vim.cmd("CodexWorkbenchAccept")
      assert.equals("accept", captured_method)
      assert.equals("all", captured_params and captured_params.scope)
    end)

    it("sends accept with the specified scope when argument is given", function()
      vim.cmd("CodexWorkbenchAccept file:src/main.rs")
      assert.equals("accept", captured_method)
      assert.equals("file:src/main.rs", captured_params and captured_params.scope)
    end)
  end)

  describe("CodexWorkbenchReject", function()
    it("sends reject with scope 'all' when called without arguments", function()
      vim.cmd("CodexWorkbenchReject")
      assert.equals("reject", captured_method)
      assert.equals("all", captured_params and captured_params.scope)
    end)

    it("sends reject with the specified scope when argument is given", function()
      vim.cmd("CodexWorkbenchReject hunk:foo.rs:0")
      assert.equals("reject", captured_method)
      assert.equals("hunk:foo.rs:0", captured_params and captured_params.scope)
    end)
  end)

  describe("CodexWorkbenchAbandon", function()
    it("sends abandon_review with scope 'all'", function()
      vim.cmd("CodexWorkbenchAbandon")
      assert.equals("abandon_review", captured_method)
      assert.equals("all", captured_params and captured_params.scope)
    end)
  end)

  describe("CodexWorkbenchThreads and Ask", function()
    it("resolves command arguments with the snapshot captured at ask time", function()
      local snap = { file = "/before.lua", lnum = 1, lines = { "before" }, selection = "" }
      local seen_snap
      context.snapshot = function()
        return snap
      end
      context.resolve = function(prompt, _, resolved_snap)
        seen_snap = resolved_snap
        return "resolved " .. prompt
      end
      bridge.state.thread_id = "thread-1"
      bridge.state.phase = "ready"

      vim.cmd("CodexWorkbenchAsk @this")

      assert.is_true(seen_snap == snap)
      assert.equals("resolved @this", captured_params and captured_params.prompt)
    end)

    it("keeps the ask snapshot when vim.ui.input changes the current buffer", function()
      local snap = { file = "/before.lua", lnum = 1, lines = { "before" }, selection = "" }
      local scratch
      local seen_snap
      context.snapshot = function()
        return snap
      end
      context.resolve = function(_, _, resolved_snap)
        seen_snap = resolved_snap
        return resolved_snap.file
      end
      vim.ui.input = function(_, callback)
        scratch = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(scratch, "/after.lua")
        vim.api.nvim_set_current_buf(scratch)
        callback("@this")
      end
      bridge.state.thread_id = "thread-1"
      bridge.state.phase = "ready"

      vim.cmd("CodexWorkbenchAsk")

      if scratch then
        pcall(vim.api.nvim_buf_delete, scratch, { force = true })
      end
      assert.is_true(seen_snap == snap)
      assert.equals("/before.lua", captured_params and captured_params.prompt)
    end)

    it("uses the selected resumed thread for the next ask", function()
      bridge.state.thread_id = "old-thread"
      bridge.state.phase = "ready"
      vim.ui.select = function(items, _, callback)
        callback(items[2])
      end

      vim.cmd("CodexWorkbenchThreads")
      vim.cmd("CodexWorkbenchAsk hello")

      assert.equals("thread-99", bridge.state.thread_id)
      assert.equals("ask", captured_method)
      assert.equals("thread-99", captured_params and captured_params.thread_id)
      assert.is_false(captured_params and captured_params.new_thread)
    end)

    it("uses a new thread for the next ask after selecting New thread", function()
      bridge.state.thread_id = "old-thread"
      bridge.state.phase = "ready"
      vim.ui.select = function(items, _, callback)
        callback(items[1])
      end

      vim.cmd("CodexWorkbenchThreads")
      vim.cmd("CodexWorkbenchAsk hello")

      assert.is_nil(bridge.state.thread_id)
      assert.equals("ask", captured_method)
      assert.is_nil(captured_params and captured_params.thread_id)
      assert.is_true(captured_params and captured_params.new_thread)
    end)

    it("retries the last ask payload", function()
      bridge.state.thread_id = "thread-1"
      bridge.state.phase = "ready"

      vim.cmd("CodexWorkbenchAsk hello")
      commands.retry_last()

      assert.equals("ask", request_calls[#request_calls].method)
      assert.equals("hello", request_calls[#request_calls].params.prompt)
      assert.equals("thread-1", request_calls[#request_calls].params.thread_id)
    end)
  end)
end)
