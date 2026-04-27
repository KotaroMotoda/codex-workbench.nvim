local M = {}

local function path()
  return vim.fn.stdpath("state") .. "/codex-workbench/workbench.log"
end

---@return string
function M.path()
  return path()
end

---@param level string
---@param code string
---@param details any
function M.write(level, code, details)
  local file = path()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local entry = { ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), level = level, code = code }
  if details ~= nil then
    entry.details = details
  end
  local ok, line = pcall(vim.json.encode, entry)
  if not ok then
    line = vim.json.encode({ ts = entry.ts, level = level, code = code })
  end
  vim.fn.writefile({ line }, file, "a")
end

function M.open()
  local file = path()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  if vim.fn.filereadable(file) == 0 then
    vim.fn.writefile({}, file)
  end

  -- Render JSONL entries into a human-readable scratch buffer.
  local raw_lines = vim.fn.readfile(file)
  local pretty = {}
  for _, line in ipairs(raw_lines) do
    if line ~= "" then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" then
        local details_str = ""
        if entry.details ~= nil then
          local enc_ok, enc = pcall(vim.json.encode, entry.details)
          details_str = " " .. (enc_ok and enc or vim.inspect(entry.details))
        end
        table.insert(
          pretty,
          string.format("[%s] %s %s%s", entry.ts or "?", entry.level or "?", entry.code or "?", details_str)
        )
      else
        table.insert(pretty, line)
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "codex-workbench://log")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pretty)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end

return M
