local M = {}

local function path()
  return vim.fn.stdpath("state") .. "/codex-workbench/workbench.log"
end

local function stringify(value)
  if type(value) == "string" then
    return value
  end
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return vim.inspect(value)
end

function M.path()
  return path()
end

function M.write(level, message, details)
  local file = path()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local lines = {
    string.format("[%s] %s %s", os.date("%Y-%m-%dT%H:%M:%S%z"), level, message),
  }
  if details ~= nil then
    table.insert(lines, stringify(details))
  end
  vim.fn.writefile(lines, file, "a")
end

function M.open()
  local file = path()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  if vim.fn.filereadable(file) == 0 then
    vim.fn.writefile({}, file)
  end
  vim.cmd("botright split " .. vim.fn.fnameescape(file))
end

return M
