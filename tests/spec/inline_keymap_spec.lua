local inline = require("codex_workbench.ui.inline")
local bridge = require("codex_workbench.bridge")
local render = require("codex_workbench.ui.inline.render")
local review = require("codex_workbench.ui.review")
local state = require("codex_workbench.ui.inline.state")

local function item_for(path)
  return {
    patch = table.concat({
      "diff --git a/" .. path .. " b/" .. path,
      "index 1111111..2222222 100644",
      "--- a/" .. path,
      "+++ b/" .. path,
      "@@ -1,2 +1,2 @@",
      "-old",
      "+new",
      " keep",
    }, "\n"),
  }
end

describe("inline keymap", function()
  local original_request
  local original_review_open
  local tmp
  local captured
  local opened_review

  before_each(function()
    original_request = bridge.request
    original_review_open = review.open
    captured = nil
    opened_review = false
    tmp = vim.fn.tempname()
    vim.fn.writefile({ "old", "keep" }, tmp)
    inline.configure({ enabled = true, auto_show = true, prefix = "<leader>c", fallback_threshold = 3 })
    bridge.request = function(method, params, cb)
      captured = { method = method, params = params }
      if cb then
        cb({ ok = true, result = {} })
      end
    end
    review.open = function()
      opened_review = true
    end
  end)

  after_each(function()
    bridge.request = original_request
    review.open = original_review_open
    inline._reset_for_tests()
    if tmp then
      pcall(vim.fn.delete, tmp)
    end
  end)

  it("accepts the current hunk through the buffer-local mapping", function()
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    assert.is_true(inline.show(item_for(tmp), { fallback = false }))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>ca", true, false, true), "x", false)

    assert.equals("accept", captured and captured.method)
    assert.equals("hunk:" .. tmp .. ":0", captured and captured.params and captured.params.scope)
  end)

  it("clears namespace after accept succeeds", function()
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(inline.show(item_for(tmp), { fallback = false }))

    inline.accept_current(buf)

    local marks = vim.api.nvim_buf_get_extmarks(buf, render.namespace, 0, -1, { details = true })
    assert.equals(0, #marks)
  end)

  it("clears inline state when the buffer changes after display", function()
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(inline.show(item_for(tmp), { fallback = false }))
    assert.is_not_nil(state.get(buf))

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "edited" })

    local cleared = vim.wait(200, function()
      return state.get(buf) == nil
    end)
    assert.is_true(cleared)
  end)

  it("falls back instead of rejecting a modified buffer", function()
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(inline.show(item_for(tmp), { fallback = false }))
    vim.bo[buf].modified = true

    inline.reject_current(buf)

    assert.is_nil(captured)
    assert.is_true(opened_review)
  end)

  it("falls back instead of rejecting a modified file", function()
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(inline.show(item_for(tmp), { fallback = false }))
    vim.bo[buf].modified = true

    inline.reject_file(buf)

    assert.is_nil(captured)
    assert.is_true(opened_review)
  end)
end)
