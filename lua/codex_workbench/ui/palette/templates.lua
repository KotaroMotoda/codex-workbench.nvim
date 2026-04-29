local M = {}

local builtin = {
  { trigger = "/explain", prompt = "Explain @this in detail." },
  { trigger = "/fix", prompt = "Fix the bug in @selection. Diagnostics: @diagnostics" },
  { trigger = "/test", prompt = "Write tests for @selection in the project's existing test framework." },
  { trigger = "/refactor", prompt = "Refactor @selection to be more idiomatic. Keep behavior identical." },
  { trigger = "/docs", prompt = "Add doc comments for @selection." },
}

local function normalize(template)
  if type(template) ~= "table" or type(template.trigger) ~= "string" or template.trigger == "" then
    return nil
  end
  return {
    trigger = template.trigger,
    prompt = type(template.prompt) == "string" and template.prompt or "",
    detail = type(template.detail) == "string" and template.detail or nil,
  }
end

---@param user_templates table[]|nil
---@return table[]
function M.list(user_templates)
  local order = {}
  local by_trigger = {}

  local function add(template)
    local item = normalize(template)
    if not item then
      return
    end
    if not by_trigger[item.trigger] then
      table.insert(order, item.trigger)
    end
    by_trigger[item.trigger] = item
  end

  for _, template in ipairs(builtin) do
    add(template)
  end
  for _, template in ipairs(user_templates or {}) do
    add(template)
  end

  local result = {}
  for _, trigger in ipairs(order) do
    table.insert(result, by_trigger[trigger])
  end
  return result
end

return M
