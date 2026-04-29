local M = {}
local log = require("codex_workbench.log")
local error_prompt = require("codex_workbench.ui.error_prompt")
local progress = require("codex_workbench.ui.progress")
local last_ask = nil

function M.set_last_ask(payload)
  last_ask = payload
end

--- Reports a failed bridge response to the user. Always logs the full
--- structured payload so that the popup can stay short and code-driven.
local function report_error(response)
  if response and not response.ok then
    -- Surface an error toast and stop any active spinner so failures
    -- never leave a progress toast hanging.
    progress.error("Error")
    log.write("ERROR", "bridge_error", response)
    error_prompt.show(response)
    return true
  end
  return false
end

function M.retry_last()
  if not last_ask then
    vim.notify("No ask request to retry", vim.log.levels.WARN, { title = "codex-workbench" })
    return
  end
  local bridge = require("codex_workbench.bridge")
  local output = require("codex_workbench.ui.output")
  output.open()
  output.start_turn()
  progress.set("Asking")
  bridge.request("ask", last_ask, report_error)
end

---@param opts CodexWorkbenchOpts
function M.register(opts)
  local bridge = require("codex_workbench.bridge")
  local context = require("codex_workbench.context")
  local output = require("codex_workbench.ui.output")
  local review = require("codex_workbench.ui.review")
  local thread_picker = require("codex_workbench.ui.thread_picker")

  output.configure(opts.ui.output)
  review.configure(opts.ui.review)
  progress.configure(opts.ui.progress)
  error_prompt.configure(opts.errors)

  local next_ask_new_thread = false

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
      progress.set(method == "accept" and "Applying review" or "Rejecting review")
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
    local snap = context.snapshot()

    local function run(prompt, thread)
      if not prompt or prompt == "" then
        return
      end
      next_ask_new_thread = false
      output.open()
      output.start_turn()
      progress.set("Asking")
      M.set_last_ask({
        prompt = context.resolve(prompt, opts, snap),
        thread_id = thread.new_thread and nil or thread.thread_id,
        new_thread = thread.new_thread == true,
      })
      bridge.request("ask", last_ask, report_error)
    end

    local function ask_with_input(thread)
      if command.args and command.args ~= "" then
        run(command.args, thread)
      else
        vim.ui.input({ prompt = "Codex: " }, function(prompt)
          run(prompt, thread)
        end)
      end
    end

    with_bridge(function()
      if next_ask_new_thread then
        ask_with_input({ new_thread = true })
        return
      end

      -- アクティブスレッドがあればピッカーをスキップ
      if bridge.state.thread_id and bridge.state.phase == "ready" then
        ask_with_input({ thread_id = bridge.state.thread_id })
        return
      end

      bridge.request("threads", {}, function(threads_response)
        if report_error(threads_response) then
          return
        end
        thread_picker.select(threads_response.result or {}, function(thread)
          if not thread then
            return
          end
          ask_with_input(thread)
        end)
      end)
    end)
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

  vim.api.nvim_create_user_command("CodexWorkbenchThreads", function()
    with_bridge(function()
      bridge.request("threads", {}, function(response)
        if report_error(response) then
          return
        end
        thread_picker.select(response.result or {}, function(selected)
          if not selected then
            return
          end
          if selected.new_thread then
            next_ask_new_thread = true
            bridge.state.thread_id = nil
            bridge.state.phase = "ready"
            vim.notify("New thread will be used for the next ask", vim.log.levels.INFO, { title = "codex-workbench" })
          else
            bridge.request("resume", { thread_id = selected.thread_id }, function(resume_response)
              if not report_error(resume_response) then
                local result = resume_response.result or {}
                next_ask_new_thread = false
                bridge.state.thread_id = result.thread_id or selected.thread_id
                bridge.state.phase = "ready"
              end
            end)
          end
        end)
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
          local result = response.result or {}
          local lines = {
            "phase:   " .. (result.phase or "?"),
            "thread:  " .. (result.thread_id or "(none)"),
            "shadow:  " .. (result.shadow_path or "(none)"),
            "review:  " .. (result.pending_review and "pending" or "none"),
          }
          vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Codex Status" })
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
          log.write("ERROR", "binary_install_failed", {
            stderr = result.stderr,
            stdout = result.stdout,
            code = result.code,
          })
          error_prompt.show({ code = "internal_error" })
        end
      end)
    end)
  end, {})
end

return M
