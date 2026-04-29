local error_prompt = require("codex_workbench.ui.error_prompt")

describe("error_prompt", function()
  local original_notify
  local original_select
  local original_cmd

  before_each(function()
    original_notify = vim.notify
    original_select = vim.ui.select
    original_cmd = vim.cmd
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.select = original_select
    vim.cmd = original_cmd
    error_prompt.configure({ interactive = true, show_log_path = true })
  end)

  it("uses notify only when interactive is false", function()
    local notified
    local selected = false
    vim.notify = function(message, level, opts)
      notified = { message = message, level = level, opts = opts }
    end
    vim.ui.select = function()
      selected = true
    end

    error_prompt.configure({ interactive = false, show_log_path = false })
    error_prompt.show({ ok = false, error_code = "codex_not_found" })
    vim.wait(100, function()
      return notified ~= nil
    end)

    assert.is_false(selected)
    assert.equals(vim.log.levels.ERROR, notified.level)
    assert.equals("codex-workbench", notified.opts.title)
  end)

  it("passes actions to vim.ui.select when interactive is true", function()
    local captured_items
    local captured_opts
    vim.ui.select = function(items, opts, callback)
      captured_items = items
      captured_opts = opts
      callback(nil)
    end

    error_prompt.configure({ interactive = true, show_log_path = false })
    error_prompt.show({ ok = false, error_code = "codex_not_found" })
    vim.wait(100, function()
      return captured_items ~= nil
    end)

    assert.equals("Codex bridge binary was not found.", captured_opts.prompt)
    assert.equals("[i] bridge をインストール", captured_opts.format_item(captured_items[1]))
  end)

  it("runs the selected command action", function()
    local cmd
    vim.cmd = function(command)
      cmd = command
    end
    vim.ui.select = function(items, _, callback)
      callback(items[1])
    end

    error_prompt.configure({ interactive = true, show_log_path = false })
    error_prompt.show({ ok = false, error_code = "codex_not_found" })
    vim.wait(100, function()
      return cmd ~= nil
    end)

    assert.equals("CodexWorkbenchInstallBinary", cmd)
  end)
end)
