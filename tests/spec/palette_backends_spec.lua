local backends = require("codex_workbench.ui.palette.backends")

describe("palette backends", function()
  it("falls back to vim.ui.select when picker plugins are unavailable", function()
    local backend = backends.pick()
    assert.equals("vim.ui.select", backend.name)
  end)
end)
