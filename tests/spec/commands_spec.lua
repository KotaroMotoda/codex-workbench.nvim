-- busted specs for codex_workbench.commands
local commands = require("codex_workbench.commands")
local bridge = require("codex_workbench.bridge")
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
    },
    contexts = {},
    session = { auto_resume = false },
  }
end

describe("commands", function()
  local original_initialize
  local original_request
  local original_ui_select
  local original_output_open
  local original_output_start_turn
  local captured_method
  local captured_params
  local request_calls

  before_each(function()
    original_initialize = bridge.initialize
    original_request = bridge.request
    original_ui_select = vim.ui.select
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
      end
    end
    output.open = function() end
    output.start_turn = function() end

    commands.register(make_opts())
  end)

  after_each(function()
    bridge.initialize = original_initialize
    bridge.request = original_request
    vim.ui.select = original_ui_select
    output.open = original_output_open
    output.start_turn = original_output_start_turn
    bridge.state.thread_id = nil
    bridge.state.phase = "idle"
  end)

  describe("registration", function()
    local expected_commands = {
      "CodexWorkbenchOpen",
      "CodexWorkbenchAsk",
      "CodexWorkbenchReview",
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
  end)
end)
