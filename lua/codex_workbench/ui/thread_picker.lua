local M = {}

local function when(value)
  if type(value) ~= "number" then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M", value)
end

local function text(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function label(item)
  if item.new_thread then
    return item.label or "New thread"
  end
  local title = text(item.name) or text(item.preview) or text(item.id) or "(untitled)"
  local meta = {}
  local status = text(item.status)
  local source = text(item.source)
  if status then
    table.insert(meta, status)
  end
  if source then
    table.insert(meta, source)
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
  local repo_name = vim.fn.fnamemodify(text(project.workspace) or "", ":t")
  local current_thread_id = text(project.current_thread_id)
  local choices = {
    { new_thread = true, label = "New thread" .. (repo_name ~= "" and (" for " .. repo_name) or "") },
  }
  local seen = {}
  for _, thread in ipairs(payload.threads or {}) do
    local id = text(thread.id)
    if id and not seen[id] then
      seen[id] = true
      local choice = vim.tbl_extend("force", {}, thread)
      choice.id = id
      choice.current = id == current_thread_id
      table.insert(choices, choice)
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
      callback({ thread_id = text(choice.id) })
    end
  end)
end

return M
