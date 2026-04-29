local M = {
  opts = {
    interactive = true,
    show_log_path = true,
  },
}

function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

---@param code string
---@return table
function M.for_code(code)
  return require("codex_workbench.error_codes").actions_for(code)
end

local function message_with_log_path(message)
  if M.opts.show_log_path == false then
    return message
  end
  return message .. "\nLog: " .. require("codex_workbench.log").path()
end

local function resolve_action_fn(fn)
  if type(fn) == "function" then
    return fn
  end
  if type(fn) == "string" then
    return require("codex_workbench.ui.error_actions")[fn]
  end
  return nil
end

---@param response any
function M.show(response)
  local error_codes = require("codex_workbench.error_codes")
  local code = error_codes.code(response)
  local actions = error_codes.actions_for(code)
  local message = error_codes.format(response)

  if M.opts.interactive == false or #actions == 0 then
    vim.schedule(function()
      vim.notify(message_with_log_path(message), vim.log.levels.ERROR, { title = "codex-workbench" })
    end)
    return
  end

  local items = vim.deepcopy(actions)
  vim.schedule(function()
    vim.ui.select(items, {
      prompt = message_with_log_path(message),
      format_item = function(item)
        return "[" .. item.key .. "] " .. item.label
      end,
    }, function(item)
      if not item or item.key == "c" then
        return
      end
      if item.cmd then
        vim.cmd(item.cmd)
      end
      local fn = resolve_action_fn(item.fn)
      if fn then
        fn(response)
      end
    end)
  end)
end

return M
