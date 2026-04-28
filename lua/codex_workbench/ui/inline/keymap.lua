local M = {
  opts = {
    prefix = "<leader>c",
    jump = { next = "]c", prev = "[c" },
  },
  attached = {},
}

---@param opts table|nil
function M.configure(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

local function del(buf, lhs)
  pcall(vim.keymap.del, "n", lhs, { buffer = buf })
end

---@param buf integer
function M.detach(buf)
  local maps = M.attached[buf]
  if not maps then
    return
  end
  for _, lhs in ipairs(maps) do
    del(buf, lhs)
  end
  M.attached[buf] = nil
end

---@param buf integer
---@param inline table
function M.attach(buf, inline)
  M.detach(buf)
  local prefix = M.opts.prefix or "<leader>c"
  local jump = M.opts.jump or {}
  local maps = {
    prefix .. "a",
    prefix .. "r",
    prefix .. "A",
    prefix .. "R",
    prefix .. "p",
    prefix .. "d",
    jump.next or "]c",
    jump.prev or "[c",
  }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map(prefix .. "a", function()
    inline.accept_current(buf)
  end, "Codex inline accept hunk")
  map(prefix .. "r", function()
    inline.reject_current(buf)
  end, "Codex inline reject hunk")
  map(prefix .. "A", function()
    inline.accept_file(buf)
  end, "Codex inline accept file")
  map(prefix .. "R", function()
    inline.reject_file(buf)
  end, "Codex inline reject file")
  map(prefix .. "p", function()
    inline.preview_current(buf)
  end, "Codex inline preview hunk")
  map(prefix .. "d", function()
    inline.open_review()
  end, "Codex review buffer")
  map(jump.next or "]c", function()
    inline.jump(buf, 1)
  end, "Next Codex hunk")
  map(jump.prev or "[c", function()
    inline.jump(buf, -1)
  end, "Previous Codex hunk")

  M.attached[buf] = maps
end

function M.reset()
  for buf in pairs(M.attached) do
    M.detach(buf)
  end
  M.attached = {}
end

return M
