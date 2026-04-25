local M = {}

local function visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return ""
  end
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local start_line = math.min(start_pos[2], end_pos[2])
  local end_line = math.max(start_pos[2], end_pos[2])
  return table.concat(vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false), "\n")
end

local function diagnostics()
  local items = vim.diagnostic.get(0)
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, string.format("%d:%d %s", item.lnum + 1, item.col + 1, item.message))
  end
  return table.concat(lines, "\n")
end

local function changes()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return ""
  end
  local result = vim.system({ "git", "diff", "--", file }, { text = true }):wait()
  return result.stdout or ""
end

local function file_contents(path)
  local resolved = vim.fn.fnamemodify(path, ":p")
  local ok, lines = pcall(vim.fn.readfile, resolved)
  if not ok then
    return ""
  end
  return table.concat(lines, "\n")
end

function M.resolve(prompt, opts)
  opts = opts or {}
  local enabled = ((opts.contexts or {}).enabled) or {}
  local file = vim.api.nvim_buf_get_name(0)
  local replacements = {
    ["@this"] = enabled.this == false and "@this" or (file .. ":" .. vim.fn.line(".")),
    ["@buffer"] = enabled.buffer == false and "@buffer"
      or table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
    ["@selection"] = enabled.selection == false and "@selection" or visual_selection(),
    ["@diagnostics"] = enabled.diagnostics == false and "@diagnostics" or diagnostics(),
    ["@changes"] = enabled.changes == false and "@changes" or changes(),
  }

  local resolved = prompt
  for key, value in pairs(replacements) do
    resolved = resolved:gsub(vim.pesc(key), value)
  end

  if enabled.file ~= false then
    resolved = resolved:gsub("@file%((.-)%)", function(path)
      return file_contents(path)
    end)
  end

  return resolved
end

return M

