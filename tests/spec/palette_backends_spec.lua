local backends = require("codex_workbench.ui.palette.backends")

describe("palette backends", function()
  local original_select

  before_each(function()
    original_select = vim.ui.select
  end)

  after_each(function()
    vim.ui.select = original_select
  end)

  it("falls back to vim.ui.select when picker plugins are unavailable", function()
    local backend = backends.pick()
    assert.equals("vim.ui.select", backend.name)
  end)

  it("allows fallback backend show without opts", function()
    local selected
    vim.ui.select = function(entries, _, callback)
      callback(entries[1])
    end
    local backend = backends.pick()

    backend.show({
      {
        kind = "template",
        title = "/x",
        action = function()
          selected = true
        end,
      },
    })

    assert.is_true(selected)
  end)
end)
