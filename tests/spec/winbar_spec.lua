local winbar = require("codex_workbench.ui.review.winbar")
local output = require("codex_workbench.ui.output")
local output_winbar = require("codex_workbench.ui.output_winbar")

describe("winbar", function()
  after_each(function()
    winbar.clear()
  end)

  it("renders review key hints", function()
    local win = vim.api.nvim_get_current_win()
    winbar.apply(win, { kind = "review_tree" }, true)
    local rendered = winbar.render()
    assert.is_true(rendered:find("[a]", 1, true) ~= nil)
    assert.is_true(rendered:find("]f", 1, true) ~= nil)
    assert.is_true(rendered:find("[q]", 1, true) ~= nil)
  end)

  it("clears the window option when disabled", function()
    local win = vim.api.nvim_get_current_win()
    winbar.apply(win, { kind = "review_tree" }, true)
    winbar.apply(win, { kind = "review_tree" }, false)
    assert.equals("", vim.wo[win].winbar)
  end)

  it("renders compact review hints below 80 columns", function()
    local rendered = winbar.render_context({ kind = "review_tree" }, nil, 60)
    assert.is_true(rendered:find("next%-file") ~= nil)
    assert.is_true(rendered:find("accept%-all") == nil)
  end)

  it("escapes dynamic review pane fields for statusline rendering", function()
    local rendered = winbar.render_context({
      kind = "review_pane",
      path = "src/%=file.lua",
      pane = "before%pane",
      hunk_count = 2,
    }, nil, 100)

    assert.is_true(rendered:find("before%%pane", 1, true) ~= nil)
    assert.is_true(rendered:find("src/%%=file.lua", 1, true) ~= nil)
  end)

  it("renders output phase and elapsed status", function()
    local rendered = output_winbar.render({ width = 100, phase = "streaming", started_at = os.time() - 12 })
    assert.is_true(rendered:find("Codex Output", 1, true) ~= nil)
    assert.is_true(rendered:find("phase: streaming", 1, true) ~= nil)
    assert.is_true(rendered:find("elapsed", 1, true) ~= nil)
  end)

  it("clears output winbar context when the output window closes", function()
    output.configure({ winbar = true })
    output.open()
    local win = vim.api.nvim_get_current_win()
    assert.is_not_nil(winbar.contexts[win])

    vim.api.nvim_win_close(win, true)
    assert.is_true(vim.wait(100, function()
      return winbar.contexts[win] == nil
    end))
  end)
end)
