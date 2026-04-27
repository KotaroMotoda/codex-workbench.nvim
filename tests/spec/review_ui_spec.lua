-- busted specs for codex_workbench.ui.review
local review = require("codex_workbench.ui.review")

describe("review ui", function()
  local saved_opts

  before_each(function()
    saved_opts = vim.deepcopy(review.opts)
  end)

  after_each(function()
    -- Close any windows created during the test.
    if review.win and vim.api.nvim_win_is_valid(review.win) then
      pcall(vim.api.nvim_win_close, review.win, true)
    end
    if review.buf and vim.api.nvim_buf_is_valid(review.buf) then
      pcall(vim.api.nvim_buf_delete, review.buf, { force = true })
    end
    review.buf = nil
    review.win = nil
    review.current = nil
    review.opts = saved_opts
  end)

  describe("configure", function()
    it("stores the layout option", function()
      review.configure({ layout = "horizontal" })
      assert.equals("horizontal", review.opts.layout)
    end)

    it("deep-merges with existing options", function()
      review.configure({ layout = "vertical" })
      assert.equals("vertical", review.opts.layout)
    end)
  end)

  describe("render", function()
    it("creates a valid buffer", function()
      review.render(nil)
      assert.is_not_nil(review.buf)
      assert.is_true(vim.api.nvim_buf_is_valid(review.buf))
    end)

    it("shows 'No pending review' when item is nil", function()
      review.render(nil)
      local lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_not_nil(content:find("No pending review", 1, true))
    end)

    it("shows review header line", function()
      review.render(nil)
      local first = vim.api.nvim_buf_get_lines(review.buf, 0, 1, false)[1]
      assert.equals("# Codex Review", first)
    end)

    it("renders item id, turn_id, and status", function()
      local item = {
        id = "rev-abc",
        turn_id = "turn-xyz",
        status = "pending",
        files = {},
        patch = "",
      }
      review.render(item)
      local lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_not_nil(content:find("rev-abc", 1, true), "should contain review id")
      assert.is_not_nil(content:find("turn-xyz", 1, true), "should contain turn id")
      assert.is_not_nil(content:find("pending", 1, true), "should contain status")
    end)

    it("lists files in the rendered buffer", function()
      local item = {
        id = "rev-1",
        turn_id = "t1",
        status = "pending",
        files = {
          { path = "src/main.rs", file_only = false },
          { path = "Cargo.toml", file_only = true },
        },
        patch = "",
      }
      review.render(item)
      local lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_not_nil(content:find("src/main.rs", 1, true))
      assert.is_not_nil(content:find("Cargo.toml", 1, true))
      assert.is_not_nil(content:find("[file]", 1, true), "file_only files should have [file] suffix")
    end)

    it("includes the patch lines in the rendered buffer", function()
      local patch = "diff --git a/f.rs b/f.rs\n--- a/f.rs\n+++ b/f.rs\n@@ -1 +1 @@\n-old\n+new\n"
      local item = {
        id = "rev-2",
        turn_id = "t2",
        status = "pending",
        files = { { path = "f.rs", file_only = false } },
        patch = patch,
      }
      review.render(item)
      local lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_not_nil(content:find("diff --git", 1, true))
      assert.is_not_nil(content:find("+new", 1, true))
    end)

    it("buffer is not modifiable after render", function()
      review.render(nil)
      assert.is_false(vim.bo[review.buf].modifiable)
    end)

    it("stores the rendered item in current", function()
      local item = { id = "r", turn_id = "t", status = "pending", files = {}, patch = "" }
      review.render(item)
      assert.equals(item, review.current)
    end)

    it("render nil clears current", function()
      review.current = { id = "old" }
      review.render(nil)
      assert.is_nil(review.current)
    end)
  end)
end)
