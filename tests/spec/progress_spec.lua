local progress = require("codex_workbench.ui.progress")

describe("progress toast", function()
  after_each(function()
    progress.reset()
  end)

  it("opens a floating window and closes it on done", function()
    progress.configure({ enabled = true, position = "bottom_right" })
    progress.set("Asking")
    vim.wait(100, function()
      return progress.window() ~= nil
    end)
    local win = progress.window()
    assert.is_true(win ~= nil and vim.api.nvim_win_is_valid(win))

    progress.done("Done", 0)
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("closes after the configured fade delay", function()
    progress.configure({ enabled = true, position = "bottom_right", fade_ms = 20 })
    progress.set("Asking")
    vim.wait(100, function()
      return progress.window() ~= nil
    end)
    local win = progress.window()

    progress.done({ label = "Done" })

    vim.wait(300, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("uses CodexPending highlight for errors", function()
    progress.configure({ enabled = true, position = "bottom_right", fade_ms = 1000 })
    progress.error("X")
    vim.wait(100, function()
      return progress.buffer() ~= nil
    end)

    local buf = progress.buffer()
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true, hl_name = true })

    assert.equals("CodexPending", marks[1][4].hl_group)
  end)

  it("does not open a window when disabled", function()
    progress.configure({ enabled = false })
    progress.set("Asking")
    vim.wait(50)

    assert.is_nil(progress.window())
  end)

  it("repositions the existing window", function()
    progress.configure({ enabled = true, position = "bottom_right", ascii_only = true })
    progress.set("Asking")
    vim.wait(100, function()
      return progress.window() ~= nil
    end)

    local win = progress.window()
    local before = vim.api.nvim_win_get_config(win)
    progress.reposition()
    vim.wait(100)
    local after = vim.api.nvim_win_get_config(win)

    assert.equals(before.relative, after.relative)
    assert.equals(before.width, after.width)
  end)
end)
