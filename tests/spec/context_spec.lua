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

  it("replaces @this with a nearby code block and current line marker", function()
    local snap = {
      file = "/fake/test/file.lua",
      lnum = 2,
      lines = { "line 1", "line 2", "line 3" },
      selection = "",
    }
    local result = context.resolve("at @this", {}, snap)
    assert.is_not_nil(result:find("/fake/test/file.lua", 1, true), "should contain file path")
    assert.is_not_nil(result:find("```lua", 1, true), "should contain language fence")
    assert.is_not_nil(result:find(">   2: line 2", 1, true), "should mark current line")
    assert.is_nil(result:find("/fake/test/file.lua:2", 1, true), "should not use file:line format")
  end)

  it("does not replace @this when disabled", function()
    local result = context.resolve("@this", { contexts = { enabled = { this = false } } })
    assert.equals("@this", result)
  end)

  it("replaces @this with empty string when file is empty", function()
    local result = context.resolve("@this", {}, { file = "", lnum = 1, lines = {}, selection = "" })
    assert.equals("", result)
  end)

  it("keeps @this within buffer bounds for small files", function()
    local snap = { file = "/fake/test/small.lua", lnum = 1, lines = { "only" }, selection = "" }
    local result = context.resolve("@this", {}, snap)
    assert.is_not_nil(result:find(">   1: only", 1, true), "should contain the only line")
  end)

  it("replaces @buffer with all buffer lines joined by newline", function()
    local result = context.resolve("@buffer", {})
    assert.equals("line 1\nline 2\nline 3", result)
  end)

  it("replaces @buffer from the supplied snapshot", function()
    local result = context.resolve(
      "@buffer",
      {},
      { file = "/snap.lua", lnum = 1, lines = { "100% done" }, selection = "" }
    )
    assert.equals("100% done", result)
  end)

  it("does not replace @buffer when disabled", function()
    local result = context.resolve("@buffer", { contexts = { enabled = { buffer = false } } })
    assert.equals("@buffer", result)
  end)

  it("replaces @diagnostics with formatted diagnostic lines", function()
    local original_get = vim.diagnostic.get
    local seen_bufnr
    vim.diagnostic.get = function(bufnr)
      seen_bufnr = bufnr
      return { { lnum = 9, col = 3, message = "undefined var" } }
    end
    local result = context.resolve(
      "@diagnostics",
      {},
      { bufnr = 42, file = "/snap.lua", lnum = 1, lines = {}, selection = "" }
    )
    vim.diagnostic.get = original_get
    assert.equals(42, seen_bufnr)
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

  it("replaces @selection from the supplied snapshot", function()
    local result = context.resolve(
      "@selection",
      {},
      { file = "/snap.lua", lnum = 1, lines = {}, selection = "selected text" }
    )
    assert.equals("selected text", result)
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

  it("does not expand markers contained inside replacement values", function()
    local snap = {
      file = "/fake/test/file.lua",
      lnum = 1,
      lines = { "literal @buffer" },
      selection = "",
    }
    local result = context.resolve("@this", {}, snap)
    assert.is_not_nil(result:find("literal @buffer", 1, true), "should preserve marker text inside code")
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
      local seen_cmd
      vim.system = function(cmd, _)
        seen_cmd = cmd
        return {
          wait = function()
            return { code = 0, stdout = "diff output" }
          end,
        }
      end
      local result = context.resolve("@changes", {}, { file = "/snapshot.lua", lnum = 1, lines = {}, selection = "" })
      assert.equals("/snapshot.lua", seen_cmd[4])
      assert.equals("diff output", result)
    end)

    it("resolves @changes to empty string on timeout (pcall error)", function()
      vim.system = function(_, _)
        return {
          wait = function()
            error("timeout")
          end,
        }
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
