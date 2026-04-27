-- busted specs for codex_workbench.ui.thread_picker
local thread_picker = require("codex_workbench.ui.thread_picker")

describe("thread_picker.select", function()
  local function make_thread(overrides)
    return vim.tbl_extend("force", {
      id = "t1",
      name = vim.NIL,
      preview = "preview text",
      status = "notLoaded",
      source = "cli",
      updated_at = 1777036069,
    }, overrides or {})
  end

  it("calls callback with nil when user cancels", function()
    local called_with = "NOT_CALLED"
    vim.ui.select = function(_, _, callback)
      callback(nil)
    end

    thread_picker.select(
      { project = { workspace = "/tmp", current_thread_id = vim.NIL }, threads = {} },
      function(sel) called_with = sel end
    )
    assert.is_nil(called_with)
  end)

  it("calls callback with new thread sentinel when user picks first item", function()
    local selected_id = nil
    vim.ui.select = function(items, _, callback)
      callback(items[1]) -- first item is always "new thread"
    end

    thread_picker.select(
      {
        project = { workspace = "/tmp", current_thread_id = vim.NIL },
        threads = { make_thread() },
      },
      function(sel)
        selected_id = sel and sel.thread_id
      end
    )
    -- Selecting the new-thread entry produces a nil thread_id (new thread)
    assert.is_nil(selected_id)
  end)

  it("calls callback with the selected thread_id", function()
    local selected_id = nil
    vim.ui.select = function(items, _, callback)
      callback(items[2]) -- pick the existing thread
    end

    thread_picker.select(
      {
        project = { workspace = "/tmp", current_thread_id = vim.NIL },
        threads = { make_thread({ id = "thread-99" }) },
      },
      function(sel)
        selected_id = sel and sel.thread_id
      end
    )
    assert.equals("thread-99", selected_id)
  end)

  it("format_item includes the preview text", function()
    local captured_opts = nil
    vim.ui.select = function(_, opts, callback)
      captured_opts = opts
      callback(nil)
    end

    thread_picker.select(
      {
        project = { workspace = "/tmp", current_thread_id = vim.NIL },
        threads = { make_thread({ preview = "my preview", status = "notLoaded" }) },
      },
      function(_) end
    )

    assert.is_not_nil(captured_opts)
    local rendered = captured_opts.format_item({ thread_id = "t1", preview = "my preview", status = "notLoaded" })
    assert.is_true(rendered:find("my preview", 1, true) ~= nil, "format_item should include preview: " .. tostring(rendered))
  end)
end)
