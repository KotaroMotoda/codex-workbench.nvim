local M = {}

function M.register(opts)
  local bridge = require("codex_workbench.bridge")
  local context = require("codex_workbench.context")
  local output = require("codex_workbench.ui.output")
  local review = require("codex_workbench.ui.review")

  vim.api.nvim_create_user_command("CodexWorkbenchOpen", function()
    bridge.initialize(opts)
    output.open()
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchAsk", function(command)
    bridge.initialize(opts)
    local function submit(prompt)
      if not prompt or prompt == "" then
        return
      end
      output.open()
      bridge.request("ask", { prompt = context.resolve(prompt, opts) }, function(response)
        if not response.ok then
          vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
        end
      end)
    end

    if command.args and command.args ~= "" then
      submit(command.args)
    else
      vim.ui.input({ prompt = "Codex: " }, submit)
    end
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("CodexWorkbenchReview", function()
    bridge.request("review", {}, function(response)
      if response.ok then
        review.open(response.result.pending)
      else
        vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      end
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchAccept", function(command)
    bridge.request("accept", { scope = command.args ~= "" and command.args or "all" }, function(response)
      if response.ok then
        vim.cmd("checktime")
      else
        vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      end
    end)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("CodexWorkbenchReject", function(command)
    bridge.request("reject", { scope = command.args ~= "" and command.args or "all" }, function(response)
      if response.ok then
        vim.cmd("checktime")
      else
        vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      end
    end)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("CodexWorkbenchResume", function(command)
    bridge.request("resume", { thread_id = command.args ~= "" and command.args or nil }, function(response)
      if not response.ok then
        vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      end
    end)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("CodexWorkbenchFork", function()
    bridge.request("fork", {}, function(response)
      if not response.ok then
        vim.notify(response.error, vim.log.levels.ERROR, { title = "codex-workbench" })
      end
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchStatus", function()
    bridge.request("status", {}, function(response)
      print(vim.inspect(response.result or response.error))
    end)
  end, {})

  vim.api.nvim_create_user_command("CodexWorkbenchHealth", function()
    require("codex_workbench.health").check(opts)
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
