local M = {
  opts = {
    interactive = true,
  },
}

function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

---@param code string
---@return table
function M.for_code(code)
  return require("codex_workbench.error_codes").actions_for_code(code)
end

---@param response any
function M.show(response)
  if M.opts.interactive == false then
    return
  end
  local error_codes = require("codex_workbench.error_codes")
  local code = error_codes.code(response)
  local actions = code and error_codes.actions_for_code(code) or {}
  if #actions == 0 then
    return
  end

  local items = vim.deepcopy(actions)
  table.insert(items, { key = "c", label = "cancel" })
  vim.schedule(function()
    vim.ui.select(items, {
      prompt = error_codes.format(response),
      format_item = function(item)
        return "[" .. item.key .. "] " .. item.label
      end,
    }, function(item)
      if not item or item.key == "c" then
        return
      end
      if item.cmd then
        vim.cmd(item.cmd)
      elseif item.fn then
        item.fn()
      end
    end)
  end)
end

return M
