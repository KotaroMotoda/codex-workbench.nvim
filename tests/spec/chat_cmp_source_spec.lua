local source = require("codex_workbench.ui.chat.cmp_source")

describe("chat cmp source", function()
  it("uses @ as trigger character", function()
    local src = source.new()
    assert.same({ "@" }, src:get_trigger_characters())
  end)

  it("omits disabled context items", function()
    require("codex_workbench").opts = {
      contexts = {
        enabled = {
          this = true,
          buffer = false,
          selection = true,
          diagnostics = false,
          changes = false,
          file = true,
        },
      },
    }

    local labels = {}
    source.new():complete({}, function(result)
      for _, item in ipairs(result.items) do
        labels[item.label] = true
      end
    end)

    assert.is_true(labels["@this"])
    assert.is_nil(labels["@buffer"])
    assert.is_true(labels["@selection"])
    assert.is_true(labels["@file("])
  end)
end)
