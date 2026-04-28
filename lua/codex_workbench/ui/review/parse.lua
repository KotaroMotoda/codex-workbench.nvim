local M = {}

local function unquote(path)
  if not path then
    return nil
  end
  if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
    path = path:sub(2, -2)
  end
  return (path:gsub('\\"', '"'))
end

local function strip_prefix(path)
  path = unquote(path)
  if not path or path == "/dev/null" then
    return nil
  end
  return path:gsub("^[ab]/", "")
end

local function diff_paths(line)
  local old_path, new_path = line:match("^diff %-%-git a/(.-) b/(.+)$")
  if old_path then
    return old_path, new_path
  end
  old_path, new_path = line:match('^diff %-%-git ("a/.+") ("b/.+")$')
  return strip_prefix(old_path), strip_prefix(new_path)
end

local function hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end
  return {
    header = line,
    old_start = tonumber(old_start),
    old_count = old_count == "" and 1 or tonumber(old_count),
    new_start = tonumber(new_start),
    new_count = new_count == "" and 1 or tonumber(new_count),
    lines = {},
  }
end

local function classify_line(line)
  local prefix = line:sub(1, 1)
  if prefix == "+" then
    return "add", line:sub(2)
  end
  if prefix == "-" then
    return "delete", line:sub(2)
  end
  if prefix == " " then
    return "context", line:sub(2)
  end
  return "meta", line
end

---@param patch string|nil
---@return table
function M.parse(patch)
  local result = { files = {} }
  local current = nil
  local hunk = nil

  local function push_file()
    if not current then
      return
    end
    current.path = current.new_path or current.old_path or current.path
    if current.status == "D" then
      current.path = current.old_path or current.path
    end
    table.insert(result.files, current)
  end

  for _, line in ipairs(vim.split(patch or "", "\n", { plain = true })) do
    local old_path, new_path = diff_paths(line)
    if old_path or new_path then
      push_file()
      current = {
        old_path = old_path,
        new_path = new_path,
        path = new_path or old_path,
        status = "M",
        binary = false,
        hunks = {},
      }
      hunk = nil
    elseif current then
      if line:match("^new file mode ") then
        current.status = "A"
      elseif line:match("^deleted file mode ") then
        current.status = "D"
      elseif line:match("^rename from ") then
        current.status = "R"
        current.old_path = line:gsub("^rename from ", "")
      elseif line:match("^rename to ") then
        current.status = "R"
        current.new_path = line:gsub("^rename to ", "")
        current.path = current.new_path
      elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
        current.binary = true
      elseif line:match("^--- ") then
        current.old_path = strip_prefix(line:gsub("^--- ", "")) or current.old_path
        if not current.old_path then
          current.status = "A"
        end
      elseif line:match("^%+%+%+ ") then
        current.new_path = strip_prefix(line:gsub("^%+%+%+ ", "")) or current.new_path
        if not current.new_path then
          current.status = "D"
        else
          current.path = current.new_path
        end
      else
        local parsed_hunk = hunk_header(line)
        if parsed_hunk then
          hunk = parsed_hunk
          table.insert(current.hunks, hunk)
        elseif hunk then
          local kind, text = classify_line(line)
          table.insert(hunk.lines, {
            kind = kind,
            text = text,
            raw = line,
          })
        end
      end
    end
  end

  push_file()
  return result
end

return M
