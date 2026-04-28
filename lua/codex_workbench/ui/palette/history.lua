local M = {}

---@param opts table|nil
---@param callback fun(prompts: string[]): nil
function M.recent(opts, callback)
  opts = opts or {}
  local history_opts = opts.ui and opts.ui.palette and opts.ui.palette.history or {}
  if history_opts.enabled == false then
    callback({})
    return
  end

  local bridge = require("codex_workbench.bridge")
  local limit = tonumber(history_opts.limit) or 50
  bridge.initialize(opts, function(init_response)
    if not init_response.ok then
      callback({})
      return
    end
    bridge.request("recent_prompts", { limit = limit }, function(response)
      if not response.ok then
        callback({})
        return
      end
      callback(response.result and response.result.prompts or {})
    end)
  end)
end

return M
