local parse = require("codex_workbench.ui.review.parse")
local panes = require("codex_workbench.ui.review.panes")
local review = require("codex_workbench.ui.review")
local highlights = require("codex_workbench.ui.review.highlights")
local state = require("codex_workbench.ui.review.state")
local tree = require("codex_workbench.ui.review.tree")

local sample_patch = table.concat({
  "diff --git a/src/a.lua b/src/a.lua",
  "index 1111111..2222222 100644",
  "--- a/src/a.lua",
  "+++ b/src/a.lua",
  "@@ -1,3 +1,4 @@",
  " local a = 1",
  "-local b = 2",
  "+local b = 3",
  "+local c = 4",
  " return a + b",
  "diff --git a/assets/logo.png b/assets/logo.png",
  "Binary files a/assets/logo.png and b/assets/logo.png differ",
}, "\n")

local function close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

describe("review diffview", function()
  before_each(function()
    highlights.setup()
    state.reset()
  end)

  after_each(function()
    review._reset_for_tests()
    panes.reset()
  end)

  it("parses patch text into files and hunks", function()
    local parsed = parse.parse(sample_patch)
    assert.equals(2, #parsed.files)
    assert.equals("src/a.lua", parsed.files[1].path)
    assert.equals(1, #parsed.files[1].hunks)
    assert.equals("assets/logo.png", parsed.files[2].path)
    assert.is_true(parsed.files[2].binary)
  end)

  it("renders before and after buffers for a selected file", function()
    local parsed = parse.parse(sample_patch)
    vim.cmd("vnew")
    local before_win = vim.api.nvim_get_current_win()
    vim.cmd("vnew")
    local after_win = vim.api.nvim_get_current_win()

    panes.attach(before_win, after_win)
    panes.show(parsed.files[1])
    local before_buf, after_buf = panes.buffers()
    assert.equals(6, vim.api.nvim_buf_line_count(before_buf))
    assert.equals(6, vim.api.nvim_buf_line_count(after_buf))

    close_win(after_win)
    close_win(before_win)
  end)

  it("resolves current file and hunk from the selected tree file", function()
    review.configure({ mode = "diffview", tree_width = 24, winbar = false })
    review.render({
      id = "r1",
      turn_id = "t1",
      status = "pending",
      files = {},
      patch = sample_patch,
    })

    assert.equals("src/a.lua", review.current_file())
    local path, hunk = review.current_hunk()
    assert.equals("src/a.lua", path)
    assert.equals(0, hunk)
  end)

  it("renders hunk badges in the tree and honors badge settings", function()
    local parsed = parse.parse(sample_patch)
    vim.cmd("vnew")
    local tree_win = vim.api.nvim_get_current_win()

    tree.configure({ badges = true, ascii_only = true })
    tree.attach(tree_win)
    state.accept_file("src/a.lua")
    tree.render(parsed.files)

    local marks = vim.api.nvim_buf_get_extmarks(tree.buffer(), highlights.namespace, 0, -1, { details = true })
    assert.equals("[1 hunk · [ok]]", marks[1][4].virt_text[2][1])

    tree.configure({ badges = false })
    tree.render(parsed.files)
    marks = vim.api.nvim_buf_get_extmarks(tree.buffer(), highlights.namespace, 0, -1, { details = true })
    assert.equals(0, #marks)

    close_win(tree_win)
  end)
end)
