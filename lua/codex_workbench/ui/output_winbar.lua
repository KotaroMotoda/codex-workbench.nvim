local M = {}

local function key(lhs)
  return "%#CodexWinbarKey#[" .. lhs .. "]%*"
end

local function value(text)
  return "%#CodexWinbarValue#" .. text .. "%*"
end

local function elapsed(started_at)
  if not started_at then
    return "elapsed 0s"
  end
  local seconds = math.max(0, os.time() - started_at)
  return "elapsed " .. seconds .. "s"
end

function M.render(opts)
  opts = opts or {}
  local phase = opts.phase or "idle"
  if (tonumber(opts.width) or vim.o.columns) < 80 then
    return "%#CodexWinbar#Codex Output%*  " .. value("phase: " .. phase)
  end
  return "%#CodexWinbar#Codex Output%*  "
    .. key("<C-\\>")
    .. "toggle-details  "
    .. key("q")
    .. "close"
    .. "%="
    .. value("phase: " .. phase)
    .. " %#CodexWinbarMuted#- "
    .. elapsed(opts.started_at)
    .. "%*"
end

return M
