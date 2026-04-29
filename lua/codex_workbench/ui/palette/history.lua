local M = {}

local DEFAULT_LIMIT = 50

function M.enabled(opts)
  local history_opts = opts and opts.ui and opts.ui.palette and opts.ui.palette.history or {}
  return history_opts.enabled ~= false
end

function M.limit(opts)
  local history_opts = opts and opts.ui and opts.ui.palette and opts.ui.palette.history or {}
  local value = tonumber(history_opts.limit)
  if not value then
    return DEFAULT_LIMIT
  end
  return math.max(0, math.floor(value))
end

---@param opts table|nil
---@param callback fun(prompts: string[]): nil
function M.recent(opts, callback)
  opts = opts or {}
  if not M.enabled(opts) then
    callback({})
    return
  end

  local bridge = require("codex_workbench.bridge")
  local limit = M.limit(opts)
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
