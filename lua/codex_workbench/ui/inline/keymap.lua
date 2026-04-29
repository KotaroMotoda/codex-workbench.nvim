local M = {
  opts = {
    prefix = "<leader>c",
    jump = { next = "]c", prev = "[c" },
  },
  attached = {},
  listeners = {},
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
    M.listeners[buf] = nil
    return
  end
  M.listeners[buf] = nil
  for _, lhs in ipairs(maps) do
    del(buf, lhs)
  end
  M.attached[buf] = nil
end

local function attach_change_listener(buf, inline)
  local token = {}
  M.listeners[buf] = token
  local ok = pcall(vim.api.nvim_buf_attach, buf, false, {
    on_lines = function(_, changed_buf)
      if M.listeners[changed_buf] ~= token then
        return true
      end
      vim.schedule(function()
        if M.listeners[changed_buf] == token and inline.on_buffer_changed then
          inline.on_buffer_changed(changed_buf)
        end
      end)
      return true
    end,
    on_detach = function(_, detached_buf)
      if M.listeners[detached_buf] == token then
        M.listeners[detached_buf] = nil
        M.attached[detached_buf] = nil
      end
    end,
  })
  if not ok then
    M.listeners[buf] = nil
  end
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
    prefix .. "P",
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
  map(prefix .. "P", function()
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
  attach_change_listener(buf, inline)
end

function M.reset()
  for buf in pairs(M.attached) do
    M.detach(buf)
  end
  M.attached = {}
  M.listeners = {}
end

return M
