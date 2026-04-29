local templates = require("codex_workbench.ui.palette.templates")

describe("palette templates", function()
  it("returns built-ins and lets user templates override by trigger", function()
    local result = templates.list({
      { trigger = "/fix", prompt = "custom fix" },
      { trigger = "/custom", prompt = "custom prompt" },
    })

    local by_trigger = {}
    for _, item in ipairs(result) do
      by_trigger[item.trigger] = item.prompt
    end

    assert.equals("Explain @this in detail.", by_trigger["/explain"])
    assert.equals("custom fix", by_trigger["/fix"])
    assert.equals("custom prompt", by_trigger["/custom"])
  end)

  it("drops non-string details", function()
    local result = templates.list({
      { trigger = "/safe", prompt = "prompt", detail = false },
    })

    local found
    for _, item in ipairs(result) do
      if item.trigger == "/safe" then
        found = item
      end
    end

    assert.is_not_nil(found)
    assert.is_nil(found.detail)
  end)
end)
