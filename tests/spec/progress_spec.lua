local progress = require("codex_workbench.ui.progress")

describe("progress toast", function()
  after_each(function()
    progress.reset()
  end)

  it("opens a floating window and closes it on done", function()
    progress.configure({ enabled = true, position = "bottom_right" })
    progress.set("Asking")
    local win = progress.window()
    assert.is_true(win ~= nil and vim.api.nvim_win_is_valid(win))

    progress.done("Done", 0)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)
