local state = require("codex_workbench.ui.inline.state")

describe("inline state", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    vim.api.nvim_set_current_buf(buf)
    state.reset()
  end)

  after_each(function()
    state.reset()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("does not include the line after a hunk in the previous hunk range", function()
    state.set(buf, {
      path = "sample.lua",
      hunks = {
        { old_start = 1, old_count = 1, new_start = 1, new_count = 1, marker = "first" },
        { old_start = 2, old_count = 1, new_start = 2, new_count = 1, marker = "second" },
      },
    })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local hunk = state.current_hunk(buf)
    assert.equals("second", hunk.marker)
  end)
end)
