-- busted specs for codex_workbench.bridge (synchronous paths only)
local bridge = require("codex_workbench.bridge")
local error_prompt = require("codex_workbench.ui.error_prompt")

describe("bridge", function()
  local original_jobstart
  local original_chansend
  local original_jobwait
  local original_notify
  local original_error_prompt_show
  local captured_callbacks
  local error_prompt_calls

  before_each(function()
    original_jobstart = vim.fn.jobstart
    original_chansend = vim.fn.chansend
    original_jobwait = vim.fn.jobwait
    original_notify = vim.notify
    original_error_prompt_show = error_prompt.show
    captured_callbacks = nil
    error_prompt_calls = 0

    vim.fn.jobstart = function(_, opts)
      captured_callbacks = opts
      return 99
    end
    vim.fn.chansend = function(_, _) end
    vim.fn.jobwait = function(_, _)
      return { -1 }
    end
    vim.notify = function() end
    error_prompt.show = function()
      error_prompt_calls = error_prompt_calls + 1
    end

    -- Reset singleton state before each test.
    bridge.job_id = nil
    bridge.callbacks = {}
    bridge.next_id = 1
    bridge.initializing = false
    bridge.init_callbacks = {}
    bridge.stdout_pending = ""
    bridge.stderr_pending = ""
    bridge.state.initialized = false
    bridge.state.phase = "idle"
    bridge.state.thread_id = nil
    bridge.state.pending_review = nil
    bridge.state.shadow_path = nil
    error_prompt.configure({ interactive = false, show_log_path = false })
  end)

  after_each(function()
    vim.fn.jobstart = original_jobstart
    vim.fn.chansend = original_chansend
    vim.fn.jobwait = original_jobwait
    vim.notify = original_notify
    error_prompt.show = original_error_prompt_show
    bridge.job_id = nil
    bridge.callbacks = {}
    bridge.next_id = 1
    bridge.state.initialized = false
    bridge.state.phase = "idle"
    error_prompt.configure({ interactive = true, show_log_path = true })
  end)

  describe("start", function()
    it("returns true and sets job_id when jobstart succeeds", function()
      local ok = bridge.start({ binary = { path = "fake-bridge" } })
      assert.is_true(ok)
      assert.equals(99, bridge.job_id)
    end)

    it("returns false when jobstart returns zero", function()
      vim.fn.jobstart = function(_, _)
        return 0
      end
      local ok = bridge.start({ binary = { path = "fake-bridge" } })
      assert.is_false(ok)
    end)

    it("does not show an error prompt from start when jobstart fails", function()
      vim.fn.jobstart = function(_, _)
        return 0
      end
      bridge.start({ binary = { path = "fake-bridge" } })

      assert.equals(0, error_prompt_calls)
    end)

    it("returns true immediately when job is already running", function()
      bridge.job_id = 99
      local started_new = false
      vim.fn.jobstart = function(_, _)
        started_new = true
        return 100
      end
      local ok = bridge.start({ binary = { path = "fake-bridge" } })
      assert.is_true(ok)
      assert.is_false(started_new)
    end)
  end)

  describe("on_exit", function()
    it("schedules app_server_crashed delivery to pending callbacks", function()
      bridge.start({ binary = { path = "fake-bridge" } })

      local received = nil
      bridge.callbacks[1] = function(resp)
        received = resp
      end

      -- Exit code 0: graceful, suppresses notify_error.
      assert.is_not_nil(captured_callbacks)
      captured_callbacks.on_exit(99, 0)

      assert.is_nil(bridge.job_id)
      vim.wait(100, function()
        return received ~= nil
      end)
      assert.is_not_nil(received)
      assert.is_false(received.ok)
      assert.equals("app_server_crashed", received.error_code)
    end)

    it("empties callbacks table on exit", function()
      bridge.start({ binary = { path = "fake-bridge" } })
      bridge.callbacks[1] = function(_) end
      bridge.callbacks[2] = function(_) end

      captured_callbacks.on_exit(99, 0)

      assert.same({}, bridge.callbacks)
    end)

    it("resets next_id to 1 on exit", function()
      bridge.start({ binary = { path = "fake-bridge" } })
      bridge.next_id = 42

      captured_callbacks.on_exit(99, 0)

      assert.equals(1, bridge.next_id)
    end)

    it("marks bridge as not initialized on exit", function()
      bridge.start({ binary = { path = "fake-bridge" } })
      bridge.state.initialized = true
      bridge.state.phase = "ready"

      captured_callbacks.on_exit(99, 0)

      assert.is_false(bridge.state.initialized)
      assert.equals("idle", bridge.state.phase)
    end)
  end)

  describe("request", function()
    it("does not send when job_id is nil", function()
      local sent = false
      vim.fn.chansend = function(_, _)
        sent = true
      end

      bridge.request("status", {})

      assert.is_false(sent)
    end)

    it("delivers not_initialized error to callback when job_id is nil", function()
      local received = nil
      bridge.request("status", {}, function(resp)
        received = resp
      end)

      -- callback is delivered via vim.schedule; flush it synchronously.
      vim.wait(100, function()
        return received ~= nil
      end)

      assert.is_not_nil(received)
      assert.is_false(received.ok)
      assert.equals("not_initialized", received.error_code)
    end)

    it("sends JSONL-encoded payload when job is running", function()
      bridge.start({ binary = { path = "fake-bridge" } })
      local sent_data = nil
      vim.fn.chansend = function(_, data)
        sent_data = data
      end

      bridge.request("status", { key = "val" })

      assert.is_not_nil(sent_data)
      -- gsub returns (string, count); discard count before passing to decode.
      local stripped = (sent_data:gsub("\n$", ""))
      local decoded = vim.json.decode(stripped)
      assert.equals("status", decoded.method)
      assert.equals("val", decoded.params.key)
    end)

    it("registers callback and increments next_id when callback provided", function()
      bridge.start({ binary = { path = "fake-bridge" } })

      local cb = function(_) end
      bridge.request("status", {}, cb)

      assert.equals(cb, bridge.callbacks[1])
      assert.equals(2, bridge.next_id)
    end)

    it("does not register callback when none provided", function()
      bridge.start({ binary = { path = "fake-bridge" } })

      bridge.request("status", {})

      assert.same({}, bridge.callbacks)
      assert.equals(1, bridge.next_id)
    end)
  end)
end)
