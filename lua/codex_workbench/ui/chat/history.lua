local M = {}

local function normalize_item(item)
  local role = item.role or item.type or item.author or "message"
  local text = item.text or item.content or item.message
  if type(text) == "table" then
    text = vim.inspect(text)
  end
  return { role = tostring(role), text = tostring(text or "") }
end

function M.normalize(payload)
  local raw = payload and (payload.messages or payload.data or payload.items) or {}
  local messages = {}
  if type(raw) == "table" then
    for _, item in ipairs(raw) do
      table.insert(messages, normalize_item(item))
    end
  end
  return messages
end

function M.load(bridge, thread_id, callback)
  if not thread_id or thread_id == "" then
    callback({})
    return
  end
  bridge.request("thread/messages", { thread_id = thread_id, limit = 100 }, function(response)
    if not response or not response.ok then
      callback({})
      return
    end
    callback(M.normalize(response.result or {}))
  end)
end

return M
