local M = {}

local function when(value)
  if type(value) ~= "number" then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M", value)
end

local function label(item)
  if item.new_thread then
    return item.label or "New thread"
  end
  local title = item.name
  if not title or title == "" then
    title = item.preview
  end
  if not title or title == "" then
    title = item.id
  end
  local meta = {}
  if item.status and item.status ~= "" then
    table.insert(meta, item.status)
  end
  if item.source and item.source ~= "" then
    table.insert(meta, item.source)
  end
  local suffix = item.updated_at and ("  " .. when(item.updated_at)) or ""
  if #meta > 0 then
    suffix = "  [" .. table.concat(meta, "/") .. "]" .. suffix
  end
  local marker = item.current and "* " or "  "
  return marker .. title .. suffix
end

function M.select(payload, callback)
  local project = payload.project or {}
  local repo_name = vim.fn.fnamemodify(project.workspace or "", ":t")
  local choices = {
    { new_thread = true, label = "New thread" .. (repo_name ~= "" and (" for " .. repo_name) or "") },
  }
  local seen = {}
  for _, thread in ipairs(payload.threads or {}) do
    if thread.id and not seen[thread.id] then
      seen[thread.id] = true
      thread.current = thread.id == project.current_thread_id
      table.insert(choices, thread)
    end
  end

  vim.ui.select(choices, {
    prompt = "Codex thread for this repository",
    format_item = function(item)
      return item.label or label(item)
    end,
  }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    if choice.new_thread then
      callback({ new_thread = true })
    else
      callback({ thread_id = choice.id })
    end
  end)
end

return M
