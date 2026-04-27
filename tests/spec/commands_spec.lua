-- busted specs for codex_workbench.commands
local commands = require("codex_workbench.commands")
local bridge = require("codex_workbench.bridge")

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
  local captured_method
  local captured_params

  before_each(function()
    original_initialize = bridge.initialize
    original_request = bridge.request
    captured_method = nil
    captured_params = nil

    -- Stub bridge: initialize succeeds synchronously, request captures calls.
    bridge.initialize = function(_, cb)
      if cb then cb({ ok = true, result = {} }) end
    end
    bridge.request = function(method, params, cb)
      captured_method = method
      captured_params = params
      if cb then cb({ ok = true, result = {} }) end
    end

    commands.register(make_opts())
  end)

  after_each(function()
    bridge.initialize = original_initialize
    bridge.request = original_request
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
end)
