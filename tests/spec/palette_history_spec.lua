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

  it("clamps fractional and negative limits before bridge request", function()
    local seen_limit
    bridge.initialize = function(_, callback)
      callback({ ok = true })
    end
    bridge.request = function(_, params, callback)
      seen_limit = params.limit
      callback({ ok = true, result = { prompts = {} } })
    end

    history.recent({
      ui = { palette = { history = { enabled = true, limit = 2.9 } } },
    }, function(_) end)
    assert.equals(2, seen_limit)

    history.recent({
      ui = { palette = { history = { enabled = true, limit = -3 } } },
    }, function(_) end)
    assert.equals(0, seen_limit)
  end)

  it("does not initialize the bridge when history is disabled", function()
    local initialized = false
    bridge.initialize = function()
      initialized = true
    end

    local prompts
    history.recent({
      ui = { palette = { history = { enabled = false } } },
    }, function(result)
      prompts = result
    end)

    assert.is_false(initialized)
    assert.same({}, prompts)
  end)
end)
