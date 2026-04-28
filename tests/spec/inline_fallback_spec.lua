local inline = require("codex_workbench.ui.inline")
local review = require("codex_workbench.ui.review")

local function patch_for(paths)
  local lines = {}
  for _, path in ipairs(paths) do
    vim.list_extend(lines, {
      "diff --git a/" .. path .. " b/" .. path,
      "index 1111111..2222222 100644",
      "--- a/" .. path,
      "+++ b/" .. path,
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    })
  end
  return table.concat(lines, "\n")
end

describe("inline fallback", function()
  local cwd
  local dir
  local original_review_open
  local opened

  before_each(function()
    cwd = vim.uv.cwd()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.uv.chdir(dir)
    original_review_open = review.open
    opened = false
    review.open = function()
      opened = true
    end
    inline.configure({ enabled = true, auto_show = true, fallback_threshold = 3, fallback_to_review = true })
  end)

  after_each(function()
    review.open = original_review_open
    inline._reset_for_tests()
    vim.uv.chdir(cwd)
    vim.fn.delete(dir, "rf")
  end)

  it("uses review buffer for four files", function()
    for i = 1, 4 do
      vim.fn.writefile({ "old" }, "file" .. i .. ".lua")
    end
    inline.handle_review({ patch = patch_for({ "file1.lua", "file2.lua", "file3.lua", "file4.lua" }) })
    assert.is_true(opened)
  end)

  it("uses inline display for two files", function()
    vim.fn.writefile({ "old" }, "a.lua")
    vim.fn.writefile({ "old" }, "b.lua")
    inline.handle_review({ patch = patch_for({ "a.lua", "b.lua" }) })
    assert.is_false(opened)
  end)

  it("falls back when a target buffer is modified", function()
    vim.fn.writefile({ "old" }, "dirty.lua")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/dirty.lua"))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "dirty" })
    inline.handle_review({ patch = patch_for({ "dirty.lua" }) })
    assert.is_true(opened)
  end)
end)
