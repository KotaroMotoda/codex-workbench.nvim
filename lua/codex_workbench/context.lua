local M = {}

local CONTEXT_RADIUS = 5

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

local function diagnostics(bufnr)
  local ok, items = pcall(vim.diagnostic.get, bufnr or 0)
  if not ok then
    return ""
  end
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, string.format("%d:%d %s", item.lnum + 1, item.col + 1, item.message))
  end
  return table.concat(lines, "\n")
end

local function changes(file)
  if file == "" then
    return ""
  end
  local ok, result = pcall(function()
    return vim.system({ "git", "diff", "--", file }, { text = true, timeout = 2000 }):wait()
  end)
  if not ok or type(result) ~= "table" then
    return ""
  end
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

local function this_context(snap)
  if snap.file == "" then
    return ""
  end

  local lines = snap.lines or {}
  local from = math.max(1, snap.lnum - CONTEXT_RADIUS)
  local to = math.min(#lines, snap.lnum + CONTEXT_RADIUS)
  local block = {}

  for i = from, to do
    local marker = i == snap.lnum and ">" or " "
    table.insert(block, string.format("%s%4d: %s", marker, i, lines[i] or ""))
  end

  local ext = snap.file:match("%.(%w+)$") or ""
  return snap.file .. "\n```" .. ext .. "\n" .. table.concat(block, "\n") .. "\n```"
end

local function replace_once(prompt, replacements)
  local placeholders = {}
  local count = 0
  local resolved = prompt

  for _, key in ipairs({ "@this", "@buffer", "@selection", "@diagnostics", "@changes" }) do
    resolved = resolved:gsub(vim.pesc(key), function()
      count = count + 1
      local token = "\31codex_workbench_context_" .. tostring(count) .. "\31"
      placeholders[token] = replacements[key]
      return token
    end)
  end

  return resolved, placeholders
end

--- Capture the current buffer and cursor state immediately.
---@return table
function M.snapshot()
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    file = vim.api.nvim_buf_get_name(bufnr),
    lnum = vim.fn.line("."),
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    selection = visual_selection(),
  }
end

---@param prompt string
---@param opts CodexWorkbenchOpts|{}
---@param snap table|nil
---@return string
function M.resolve(prompt, opts, snap)
  snap = snap or M.snapshot()
  opts = opts or {}
  local enabled = (opts.contexts or {}).enabled or {}
  local replacements = {
    ["@this"] = enabled.this == false and "@this" or this_context(snap),
    ["@buffer"] = enabled.buffer == false and "@buffer" or table.concat(snap.lines or {}, "\n"),
    ["@selection"] = enabled.selection == false and "@selection" or (snap.selection or ""),
    ["@diagnostics"] = enabled.diagnostics == false and "@diagnostics" or diagnostics(snap.bufnr),
    ["@changes"] = enabled.changes == false and "@changes" or changes(snap.file or ""),
  }

  local resolved, placeholders = replace_once(prompt, replacements)

  if enabled.file ~= false then
    resolved = resolved:gsub("@file%((.-)%)", function(path)
      return file_contents(path)
    end)
  end

  for token, value in pairs(placeholders) do
    resolved = resolved:gsub(vim.pesc(token), function()
      return value
    end)
  end

  return resolved
end

return M
