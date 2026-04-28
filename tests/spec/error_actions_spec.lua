local error_prompt = require("codex_workbench.ui.error_prompt")

describe("error actions", function()
  it("exposes install and log actions for codex_not_found", function()
    local actions = error_prompt.for_code("codex_not_found")
    local keys = {}
    for _, action in ipairs(actions) do
      keys[action.key] = true
    end
    assert.is_true(keys.i)
    assert.is_true(keys.l)
  end)
end)
