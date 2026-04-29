local render = require("codex_workbench.ui.inline.render")

local sample_hunk = {
  old_start = 1,
  old_count = 3,
  new_start = 1,
  new_count = 4,
  lines = {
    { kind = "context", text = "local a = 1", raw = " local a = 1" },
    { kind = "delete", text = "local b = 2", raw = "-local b = 2" },
    { kind = "add", text = "local b = 3", raw = "+local b = 3" },
    { kind = "add", text = "local c = 4", raw = "+local c = 4" },
    { kind = "context", text = "return a + b", raw = " return a + b" },
  },
}

describe("inline render", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local a = 1",
      "local b = 2",
      "return a + b",
    })
  end)

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("builds virt_lines only for added lines", function()
    local lines = render.virt_lines_for_hunk(sample_hunk)
    assert.equals(2, #lines)
    assert.equals("+", lines[1][1][1])
    assert.equals(" local b = 3", lines[1][2][1])
  end)

  it("marks deleted source lines with delete highlight", function()
    render.apply(buf, { sample_hunk })
    local marks = vim.api.nvim_buf_get_extmarks(buf, render.namespace, 0, -1, { details = true })
    local found_delete = false
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].line_hl_group == "CodexInlineDelete" then
        found_delete = true
      end
    end
    assert.is_true(found_delete)
  end)

  it("clears inline extmarks for a buffer", function()
    render.apply(buf, { sample_hunk })
    render.clear(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, render.namespace, 0, -1, { details = true })
    assert.equals(0, #marks)
  end)
end)
