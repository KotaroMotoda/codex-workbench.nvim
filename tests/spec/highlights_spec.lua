local highlights = require("codex_workbench.ui.highlights")

describe("highlights", function()
  it("sets codex highlight groups with default links", function()
    highlights.setup()

    local add = vim.api.nvim_get_hl(0, { name = "CodexAdd", link = true })
    local badge = vim.api.nvim_get_hl(0, { name = "CodexBadge", link = true })

    assert.equals("DiffAdd", add.link)
    assert.equals("Special", badge.link)
  end)

  it("reapplies highlight groups after ColorScheme", function()
    require("codex_workbench").setup({ session = { auto_resume = false } })
    vim.cmd("colorscheme default")
    local add = vim.api.nvim_get_hl(0, { name = "CodexAdd", link = true })

    assert.equals("DiffAdd", add.link)
  end)
end)
