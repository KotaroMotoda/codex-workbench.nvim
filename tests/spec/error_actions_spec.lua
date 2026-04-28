local error_codes = require("codex_workbench.error_codes")
local error_prompt = require("codex_workbench.ui.error_prompt")

describe("error actions", function()
  it("exposes install and log actions for codex_not_found", function()
    local actions = error_codes.actions_for("codex_not_found")
    local keys = {}
    for _, action in ipairs(actions) do
      keys[action.key] = true
    end
    assert.is_true(keys.i)
    assert.is_true(keys.l)
    assert.is_true(keys.c)
  end)

  it("returns an empty list for unknown codes", function()
    assert.equals(0, #error_codes.actions_for("unknown_code"))
  end)

  it("exposes review and log actions for patch_apply_failed", function()
    local actions = error_prompt.for_code("patch_apply_failed")
    local keys = {}
    for _, action in ipairs(actions) do
      keys[action.key] = true
    end
    assert.is_true(keys.d)
    assert.is_true(keys.l)
  end)
end)
