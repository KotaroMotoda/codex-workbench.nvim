local parse = require("codex_workbench.ui.review.parse")
local panes = require("codex_workbench.ui.review.panes")
local highlights = require("codex_workbench.ui.review.highlights")

local patch = table.concat({
  "diff --git a/src/a.lua b/src/a.lua",
  "--- a/src/a.lua",
  "+++ b/src/a.lua",
  "@@ -1,2 +1,2 @@",
  "-old",
  "+new",
}, "\n")

local function close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

describe("review signs", function()
  before_each(function()
    highlights.setup()
  end)

  after_each(function()
    panes.reset()
  end)

  it("places add and delete sign extmarks when panes render a patch", function()
    local parsed = parse.parse(patch)
    vim.cmd("vnew")
    local before_win = vim.api.nvim_get_current_win()
    vim.cmd("vnew")
    local after_win = vim.api.nvim_get_current_win()

    panes.attach(before_win, after_win)
    panes.show(parsed.files[1])
    local before_buf, after_buf = panes.buffers()
    local before_marks = vim.api.nvim_buf_get_extmarks(before_buf, highlights.namespace, 0, -1, { details = true })
    local after_marks = vim.api.nvim_buf_get_extmarks(after_buf, highlights.namespace, 0, -1, { details = true })

    local saw_delete = false
    for _, mark in ipairs(before_marks) do
      saw_delete = saw_delete or (mark[4] and vim.trim(mark[4].sign_text or "") == "-")
    end
    local saw_add = false
    for _, mark in ipairs(after_marks) do
      saw_add = saw_add or (mark[4] and vim.trim(mark[4].sign_text or "") == "+")
    end

    assert.is_true(saw_delete)
    assert.is_true(saw_add)

    close_win(after_win)
    close_win(before_win)
  end)
end)
