-- busted specs for codex_workbench.context
local context = require("codex_workbench.context")

describe("context.resolve", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2", "line 3" })
    vim.api.nvim_buf_set_name(buf, "/fake/test/file.lua")
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("returns prompt unchanged when no context markers are present", function()
    local result = context.resolve("hello world", {})
    assert.equals("hello world", result)
  end)

  it("replaces @this with file path and line number", function()
    local result = context.resolve("at @this", {})
    assert.is_not_nil(result:find("/fake/test/file.lua:", 1, true), "should contain file path")
  end)

  it("does not replace @this when disabled", function()
    local result = context.resolve("@this", { contexts = { enabled = { this = false } } })
    assert.equals("@this", result)
  end)

  it("replaces @buffer with all buffer lines joined by newline", function()
    local result = context.resolve("@buffer", {})
    assert.equals("line 1\nline 2\nline 3", result)
  end)

  it("does not replace @buffer when disabled", function()
    local result = context.resolve("@buffer", { contexts = { enabled = { buffer = false } } })
    assert.equals("@buffer", result)
  end)

  it("replaces @diagnostics with formatted diagnostic lines", function()
    local original_get = vim.diagnostic.get
    vim.diagnostic.get = function(_)
      return { { lnum = 9, col = 3, message = "undefined var" } }
    end
    local result = context.resolve("@diagnostics", {})
    vim.diagnostic.get = original_get
    assert.equals("10:4 undefined var", result)
  end)

  it("does not replace @diagnostics when disabled", function()
    local result = context.resolve("@diagnostics", { contexts = { enabled = { diagnostics = false } } })
    assert.equals("@diagnostics", result)
  end)

  it("does not replace @selection when disabled", function()
    local result = context.resolve("@selection", { contexts = { enabled = { selection = false } } })
    assert.equals("@selection", result)
  end)

  it("replaces @file(path) with file contents joined by newline", function()
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ "hello", "world" }, tmpfile)
    local result = context.resolve("@file(" .. tmpfile .. ")", {})
    vim.fn.delete(tmpfile)
    assert.equals("hello\nworld", result)
  end)

  it("does not replace @file(...) when file context is disabled", function()
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ "content" }, tmpfile)
    local result = context.resolve("@file(" .. tmpfile .. ")", { contexts = { enabled = { file = false } } })
    vim.fn.delete(tmpfile)
    assert.equals("@file(" .. tmpfile .. ")", result)
  end)

  it("replaces @file(...) with empty string for a non-existent path", function()
    local result = context.resolve("@file(/no/such/file.txt)", {})
    assert.equals("", result)
  end)

  it("replaces multiple markers in a single prompt", function()
    local result = context.resolve("buf=@buffer end", {})
    assert.is_not_nil(result:find("line 1"), "should contain buffer content")
    assert.is_not_nil(result:find("end"), "should preserve surrounding text")
  end)

  describe("@changes", function()
    local original_system

    before_each(function()
      original_system = vim.system
    end)

    after_each(function()
      vim.system = original_system
    end)

    it("replaces @changes with git diff stdout", function()
      vim.system = function(_, _)
        return { wait = function() return { code = 0, stdout = "diff output" } end }
      end
      local result = context.resolve("@changes", {})
      assert.equals("diff output", result)
    end)

    it("resolves @changes to empty string on timeout (pcall error)", function()
      vim.system = function(_, _)
        return { wait = function() error("timeout") end }
      end
      local result = context.resolve("@changes", {})
      assert.equals("", result)
    end)

    it("does not replace @changes when disabled", function()
      local result = context.resolve("@changes", { contexts = { enabled = { changes = false } } })
      assert.equals("@changes", result)
    end)
  end)
end)
