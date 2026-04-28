local M = {}

local function command_detail(definition)
  if type(definition) ~= "string" or definition == "" then
    return nil
  end
  return definition:gsub("^%s+", ""):gsub("%s+$", "")
end

local function list_commands()
  local entries = {}
  for name, def in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^CodexWorkbench") then
      table.insert(entries, {
        kind = "command",
        title = ":" .. name,
        detail = command_detail(def.definition),
        action = function()
          vim.cmd(name)
        end,
      })
    end
  end
  table.sort(entries, function(a, b)
    return a.title < b.title
  end)
  return entries
end

local function prompt_with_prefill(prompt)
  vim.ui.input({ prompt = "Codex: ", default = prompt }, function(input)
    if input and input ~= "" then
      require("codex_workbench").ask(input)
    end
  end)
end

local function template_entries(opts)
  local palette_opts = opts.ui and opts.ui.palette or {}
  local templates = require("codex_workbench.ui.palette.templates").list(palette_opts.templates)
  return vim.tbl_map(function(template)
    return {
      kind = "template",
      title = template.trigger,
      detail = template.detail or template.prompt,
      action = function()
        prompt_with_prefill(template.prompt)
      end,
    }
  end, templates)
end

local function history_entries(prompts)
  local entries = {}
  for _, prompt in ipairs(prompts or {}) do
    table.insert(entries, {
      kind = "history",
      title = prompt,
      detail = "Recent prompt",
      action = function()
        prompt_with_prefill(prompt)
      end,
    })
  end
  return entries
end

local function concat(...)
  local result = {}
  for _, list in ipairs({ ... }) do
    for _, item in ipairs(list or {}) do
      table.insert(result, item)
    end
  end
  return result
end

---@param opts table|nil
function M.open(opts)
  opts = opts or require("codex_workbench").opts or require("codex_workbench.config").setup({})
  local palette_opts = opts.ui and opts.ui.palette or {}
  if palette_opts.enabled == false then
    return
  end

  require("codex_workbench.ui.palette.history").recent(opts, function(prompts)
    local entries = concat(list_commands(), template_entries(opts), history_entries(prompts))
    require("codex_workbench.ui.palette.backends").show(entries, { prompt = "Codex Palette > " })
  end)
end

return M
