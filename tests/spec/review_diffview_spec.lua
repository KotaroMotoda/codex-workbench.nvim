local parse = require("codex_workbench.ui.review.parse")
local panes = require("codex_workbench.ui.review.panes")
local review = require("codex_workbench.ui.review")
local tree = require("codex_workbench.ui.review.tree")
local highlights = require("codex_workbench.ui.review.highlights")

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

local function win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

describe("review diffview", function()
  before_each(function()
    highlights.setup()
  end)

  after_each(function()
    review._reset_for_tests()
    panes.reset()
  end)

  it("parses patch text into files and hunks", function()
    local parsed = parse.parse(sample_patch)
    assert.equals(2, #parsed.files)
    assert.equals("src/a.lua", parsed.files[1].path)
    assert.equals("modify", parsed.files[1].kind)
    assert.equals(1, #parsed.files[1].hunks)
    assert.equals(0, parsed.files[1].hunks[1].index)
    assert.equals("pending", parsed.files[1].hunks[1].state)
    assert.equals(1, parsed.files[1].hunks[1].old_start)
    assert.equals(1, parsed.files[1].hunks[1].new_start)
    assert.equals("assets/logo.png", parsed.files[2].path)
    assert.equals("binary", parsed.files[2].kind)
    assert.is_true(parsed.files[2].binary)
  end)

  it("classifies add, delete, rename, and binary files", function()
    local patch = table.concat({
      "diff --git a/new.lua b/new.lua",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/new.lua",
      "@@ -0,0 +1 @@",
      "+return 1",
      "diff --git a/old.lua b/old.lua",
      "deleted file mode 100644",
      "--- a/old.lua",
      "+++ /dev/null",
      "@@ -1 +0,0 @@",
      "-return 0",
      "diff --git a/name.lua b/renamed.lua",
      "similarity index 88%",
      "rename from name.lua",
      "rename to renamed.lua",
      "--- a/name.lua",
      "+++ b/renamed.lua",
      "@@ -1 +1 @@",
      "-local name = 'old'",
      "+local name = 'new'",
      "diff --git a/bin.dat b/bin.dat",
      "Binary files a/bin.dat and b/bin.dat differ",
    }, "\n")
    local parsed = parse.parse(patch)
    assert.equals("add", parsed.files[1].kind)
    assert.equals("delete", parsed.files[2].kind)
    assert.equals("rename", parsed.files[3].kind)
    assert.equals("name.lua", parsed.files[3].old_path)
    assert.equals("renamed.lua", parsed.files[3].path)
    assert.equals("binary", parsed.files[4].kind)
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

  it("moves between hunks in diffview panes", function()
    local patch = table.concat({
      "diff --git a/src/a.lua b/src/a.lua",
      "--- a/src/a.lua",
      "+++ b/src/a.lua",
      "@@ -1 +1 @@",
      "-local a = 1",
      "+local a = 2",
      "@@ -10 +10 @@",
      "-local b = 1",
      "+local b = 2",
    }, "\n")
    review.configure({ mode = "diffview", tree_width = 24, winbar = false })
    review.render({ id = "r1", turn_id = "t1", status = "pending", files = {}, patch = patch })

    local path, hunk = review.current_hunk()
    assert.equals("src/a.lua", path)
    assert.equals(0, hunk)

    vim.cmd("normal ]h")
    path, hunk = review.current_hunk()
    assert.equals("src/a.lua", path)
    assert.equals(1, hunk)

    local before_buf, after_buf = panes.buffers()
    assert.equals(4, vim.api.nvim_win_get_cursor(win_for_buf(before_buf))[1])
    assert.equals(4, vim.api.nvim_win_get_cursor(win_for_buf(after_buf))[1])
  end)

  it("uses the last focused pane hunk when actions run from the tree", function()
    local patch = table.concat({
      "diff --git a/src/a.lua b/src/a.lua",
      "--- a/src/a.lua",
      "+++ b/src/a.lua",
      "@@ -1 +1 @@",
      "-local a = 1",
      "+local a = 2",
      "@@ -10 +10 @@",
      "-local b = 1",
      "+local b = 2",
    }, "\n")
    review.configure({ mode = "diffview", tree_width = 24, winbar = false })
    review.render({ id = "r1", turn_id = "t1", status = "pending", files = {}, patch = patch })

    local before_buf = panes.buffers()
    local before_win = win_for_buf(before_buf)
    vim.api.nvim_set_current_win(before_win)
    vim.api.nvim_win_set_cursor(before_win, { 4, 0 })
    vim.cmd("doautocmd <nomodeline> CursorMoved")

    vim.api.nvim_set_current_win(tree.window())
    local path, hunk = review.current_hunk()
    assert.equals("src/a.lua", path)
    assert.equals(1, hunk)
  end)
end)
