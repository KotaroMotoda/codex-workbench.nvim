local M = {}

local state = {
  accepted_hunks = {},
  rejected_hunks = {},
  accepted_files = {},
  rejected_files = {},
}

local function ensure_set(bucket, path)
  bucket[path] = bucket[path] or {}
  return bucket[path]
end

function M.reset()
  state.accepted_hunks = {}
  state.rejected_hunks = {}
  state.accepted_files = {}
  state.rejected_files = {}
end

function M.accept_file(path)
  state.accepted_files[path] = true
  state.rejected_files[path] = nil
end

function M.reject_file(path)
  state.rejected_files[path] = true
  state.accepted_files[path] = nil
end

function M.accept_hunk(path, hunk_index)
  ensure_set(state.accepted_hunks, path)[hunk_index] = true
  if state.rejected_hunks[path] then
    state.rejected_hunks[path][hunk_index] = nil
  end
end

function M.reject_hunk(path, hunk_index)
  ensure_set(state.rejected_hunks, path)[hunk_index] = true
  if state.accepted_hunks[path] then
    state.accepted_hunks[path][hunk_index] = nil
  end
end

function M.is_accepted(path, hunk_index)
  return state.accepted_files[path] == true
    or (state.accepted_hunks[path] and state.accepted_hunks[path][hunk_index] == true)
end

function M.is_rejected(path, hunk_index)
  return state.rejected_files[path] == true
    or (state.rejected_hunks[path] and state.rejected_hunks[path][hunk_index] == true)
end

local function count(bucket, path, total)
  if bucket[path] then
    return total
  end
  local set = bucket == state.accepted_files and state.accepted_hunks[path] or state.rejected_hunks[path]
  local n = 0
  for _ in pairs(set or {}) do
    n = n + 1
  end
  return n
end

---@param file table
---@param opts table|nil
---@return string
function M.badge(file, opts)
  opts = opts or {}
  if file.binary then
    return "[binary]"
  end
  local total = #(file.hunks or {})
  local ok = opts.ascii_only and "[ok]" or "✓"
  local ng = opts.ascii_only and "[ng]" or "✗"
  local accepted = count(state.accepted_files, file.path, total)
  local rejected = count(state.rejected_files, file.path, total)
  if total == 0 then
    return "[0 hunks]"
  end
  if accepted == total then
    return string.format("[%d hunk%s · %s]", total, total == 1 and "" or "s", ok)
  end
  if rejected == total then
    return string.format("[%d hunk%s · %s]", total, total == 1 and "" or "s", ng)
  end
  if accepted > 0 then
    return string.format("[%d/%d %s]", accepted, total, ok)
  end
  if rejected > 0 then
    return string.format("[%d/%d %s]", rejected, total, ng)
  end
  return string.format("[%d hunk%s]", total, total == 1 and "" or "s")
end

return M
