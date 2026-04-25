local M = {}

function M.component()
  local bridge = require("codex_workbench.bridge")
  if not bridge.state.initialized then
    return "CodexWorkbench:off"
  end
  if bridge.state.pending_review then
    return "CodexWorkbench:review"
  end
  return "CodexWorkbench:ready"
end

return M

