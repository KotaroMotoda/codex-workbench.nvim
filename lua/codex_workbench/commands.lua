local M = {}
local log = require("codex_workbench.log")

local function report_error(response)
  if response and not response.ok then
    local message = response.error or "request failed"
    log.write("ERROR", message, response)
    vim.notify(message .. "\nLog: " .. log.path(), vim.log.levels.ERROR, { title = "codex-workbench" })
    return true
  end
  return false
end

function M.register(opts)
  local bridge = require("codex_workbench.bridge")
  local context = require("codex_workbench.context")
  local output = require("codex_workbench.ui.output")
  local review = require("codex_workbench.ui.review")

  output.configure(opts.ui.output)
  review.configure(opts.ui.review)

  local function with_bridge(callback)
    bridge.initialize(opts, function(response)
      if report_error(response) then
        return
      end
      callback()
    end)
  end

  local function review_action(method, scope)
    with_bridge(function()
      bridge.request(method, { scope = scope or "all" }, function(response)
        if not report_error(response) then
          vim.cmd("checktime")
        end
      end)
    end)
  end

  vim.api.nvim_create_user_command("CodexWorkbenchOpen", function()
    with_bridge(function()
      output.open()
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchAsk", function(command)
    local function submit(prompt)
      if not prompt or prompt == "" then
        return
      end
      with_bridge(function()
        output.open()
        output.start_turn()
        bridge.request("ask", { prompt = context.resolve(prompt, opts) }, report_error)
      end)
    end

    if command.args and command.args ~= "" then
      submit(command.args)
    else
      vim.ui.input({ prompt = "Codex: " }, submit)
    end
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("CodexWorkbenchReview", function()
    with_bridge(function()
      bridge.request("review", {}, function(response)
        if not report_error(response) then
          review.open(response.result.pending)
        end
      end)
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchAccept", function(command)
    review_action("accept", command.args ~= "" and command.args or "all")
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("CodexWorkbenchReject", function(command)
    review_action("reject", command.args ~= "" and command.args or "all")
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("CodexWorkbenchAbandon", function()
    review_action("abandon_review", "all")
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchResume", function(command)
    with_bridge(function()
      bridge.request("resume", { thread_id = command.args ~= "" and command.args or nil }, report_error)
    end)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("CodexWorkbenchFork", function()
    with_bridge(function()
      bridge.request("fork", {}, report_error)
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchStatus", function()
    with_bridge(function()
      bridge.request("status", {}, function(response)
        if not report_error(response) then
          print(vim.inspect(response.result))
        end
      end)
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchToggleDetails", function()
    output.toggle_details()
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchLogs", function()
    log.open()
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchHealth", function()
    with_bridge(function()
      require("codex_workbench.health").check(opts)
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchInstallBinary", function()
    local script = debug.getinfo(1, "S").source:gsub("^@", "")
    local root = vim.fn.fnamemodify(script, ":p:h:h:h")
    vim.system({ root .. "/scripts/install_binary.sh" }, { text = true }, function(result)
      vim.schedule(function()
        if result.code == 0 then
          vim.notify("Installed: " .. vim.trim(result.stdout or ""), vim.log.levels.INFO, { title = "codex-workbench" })
        else
          vim.notify(result.stderr ~= "" and result.stderr or "install failed", vim.log.levels.ERROR, { title = "codex-workbench" })
        end
      end)
    end)
  end, {})
end

return M
