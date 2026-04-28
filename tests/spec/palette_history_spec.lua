local bridge = require("codex_workbench.bridge")
local history = require("codex_workbench.ui.palette.history")

describe("palette history", function()
  local original_initialize
  local original_request

  before_each(function()
    original_initialize = bridge.initialize
    original_request = bridge.request
  end)

  after_each(function()
    bridge.initialize = original_initialize
    bridge.request = original_request
  end)

  it("loads recent prompts from the bridge", function()
    local seen_method
    local seen_limit
    local prompts

    bridge.initialize = function(_, callback)
      callback({ ok = true })
    end
    bridge.request = function(method, params, callback)
      seen_method = method
      seen_limit = params.limit
      callback({ ok = true, result = { prompts = { "explain @this", "fix @selection" } } })
    end

    history.recent({
      ui = { palette = { history = { enabled = true, limit = 2 } } },
    }, function(result)
      prompts = result
    end)

    assert.equals("recent_prompts", seen_method)
    assert.equals(2, seen_limit)
    assert.same({ "explain @this", "fix @selection" }, prompts)
  end)
end)
