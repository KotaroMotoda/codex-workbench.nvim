local M = {}

local function entry_label(entry)
  local prefix = ({
    command = "cmd",
    template = "slash",
    history = "history",
  })[entry.kind] or entry.kind
  local label = "[" .. prefix .. "] " .. entry.title
  if entry.detail and entry.detail ~= "" then
    label = label .. " - " .. entry.detail
  end
  return label
end

local function select_fallback(entries, opts)
  vim.ui.select(entries, {
    prompt = opts.prompt,
    format_item = entry_label,
  }, function(choice)
    if choice and choice.action then
      choice.action()
    end
  end)
end

local function telescope_backend()
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return nil
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  return {
    name = "telescope",
    show = function(entries, opts)
      pickers
        .new({}, {
          prompt_title = opts.prompt or "Codex Palette",
          finder = finders.new_table({
            results = entries,
            entry_maker = function(entry)
              return {
                value = entry,
                display = entry_label(entry),
                ordinal = table.concat({ entry.kind or "", entry.title or "", entry.detail or "" }, " "),
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local selected = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if selected and selected.value and selected.value.action then
                selected.value.action()
              end
            end)
            return true
          end,
        })
        :find()
    end,
  }
end

local function snacks_backend()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return nil
  end

  return {
    name = "snacks",
    show = function(entries, opts)
      snacks.picker.pick({
        title = opts.prompt or "Codex Palette",
        items = vim.tbl_map(function(entry)
          return vim.tbl_extend("force", entry, { text = entry_label(entry) })
        end, entries),
        format = function(item)
          return { { item.text } }
        end,
        confirm = function(picker, item)
          picker:close()
          if item and item.action then
            item.action()
          end
        end,
      })
    end,
  }
end

local function fzf_lua_backend()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return nil
  end

  return {
    name = "fzf-lua",
    show = function(entries, opts)
      local labels = {}
      local by_label = {}
      for index, entry in ipairs(entries) do
        local label = entry_label(entry)
        if by_label[label] then
          label = label .. " (" .. index .. ")"
        end
        table.insert(labels, label)
        by_label[label] = entry
      end
      fzf.fzf_exec(labels, {
        prompt = opts.prompt or "Codex Palette > ",
        actions = {
          ["default"] = function(selected)
            local entry = selected and by_label[selected[1]]
            if entry and entry.action then
              entry.action()
            end
          end,
        },
      })
    end,
  }
end

---@return table
function M.pick()
  for _, factory in ipairs({ telescope_backend, snacks_backend, fzf_lua_backend }) do
    local ok, backend = pcall(factory)
    if ok and backend then
      return backend
    end
  end
  return {
    name = "vim.ui.select",
    show = select_fallback,
  }
end

M._entry_label = entry_label

function M.show(entries, opts)
  local fallback = {
    name = "vim.ui.select",
    show = select_fallback,
  }
  for _, factory in ipairs({ telescope_backend, snacks_backend, fzf_lua_backend }) do
    local ok, backend = pcall(factory)
    if ok and backend then
      local shown = pcall(backend.show, entries, opts or {})
      if shown then
        return backend.name
      end
    end
  end
  fallback.show(entries, opts or {})
  return fallback.name
end

return M
