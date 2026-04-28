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
end)
