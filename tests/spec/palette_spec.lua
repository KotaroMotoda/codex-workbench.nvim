local palette = require("codex_workbench.ui.palette")
local backends = require("codex_workbench.ui.palette.backends")
local codex_workbench = require("codex_workbench")

describe("palette", function()
  local original_show
  local original_input
  local original_ask

  before_each(function()
    original_show = backends.show
    original_input = vim.ui.input
    original_ask = codex_workbench.ask
  end)

  after_each(function()
    backends.show = original_show
    vim.ui.input = original_input
    codex_workbench.ask = original_ask
  end)

  it("submits template prompts without resolving context markers", function()
    local captured_prompt
    local captured_opts

    backends.show = function(entries)
      for _, entry in ipairs(entries) do
        if entry.kind == "template" and entry.title == "/raw" then
          entry.action()
          return
        end
      end
    end
    vim.ui.input = function(opts, callback)
      callback(opts.default)
    end
    codex_workbench.ask = function(prompt, opts)
      captured_prompt = prompt
      captured_opts = opts
    end

    palette.open({
      ui = {
        palette = {
          enabled = true,
          history = { enabled = false },
          templates = {
            { trigger = "/raw", prompt = "check @this" },
          },
        },
      },
    })

    assert.equals("check @this", captured_prompt)
    assert.is_false(captured_opts.resolve_context)
  end)
end)
