local M = {}

M.namespace = vim.api.nvim_create_namespace("codex_workbench/inline")

local MAX_VISIBLE_ADD_LINES = 100

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CodexInlineAddSign", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "CodexInlineDeleteSign", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CodexInlineAdd", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "CodexInlineDelete", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CodexInlineMuted", { default = true, link = "Comment" })
end

local function add_virt_line(lines, sign, text, sign_hl, text_hl)
  table.insert(lines, {
    { sign, sign_hl },
    { " " .. text, text_hl },
  })
end

---@param hunk table
---@return table[]
function M.virt_lines_for_hunk(hunk)
  local virt_lines = {}
  local hidden = 0
  for _, line in ipairs(hunk.lines or {}) do
    if line.kind == "add" then
      if #virt_lines < MAX_VISIBLE_ADD_LINES then
        add_virt_line(virt_lines, "+", line.text or "", "CodexInlineAddSign", "CodexInlineAdd")
      else
        hidden = hidden + 1
      end
    end
  end
  if hidden > 0 then
    add_virt_line(
      virt_lines,
      "+",
      ("(%d lines hidden, open review for full diff)"):format(hidden),
      "CodexInlineMuted",
      "CodexInlineMuted"
    )
  end
  return virt_lines
end

---@param buf integer
---@param hunk table
function M.mark_deletes(buf, hunk)
  local old_line = hunk.old_start or 1
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, line in ipairs(hunk.lines or {}) do
    if line.kind == "delete" then
      if old_line >= 1 and old_line <= line_count then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.namespace, old_line - 1, 0, {
          line_hl_group = "CodexInlineDelete",
          virt_text = { { " (removing)", "CodexInlineMuted" } },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end
      old_line = old_line + 1
    elseif line.kind == "context" then
      old_line = old_line + 1
    end
  end
end

---@param buf integer
---@param hunk table
function M.apply_hunk(buf, hunk)
  local virt_lines = M.virt_lines_for_hunk(hunk)
  if #virt_lines > 0 then
    local anchor = math.max((hunk.old_start or hunk.new_start or 1) + math.max((hunk.old_count or 1) - 1, 0), 1)
    anchor = math.min(anchor, vim.api.nvim_buf_line_count(buf))
    pcall(vim.api.nvim_buf_set_extmark, buf, M.namespace, anchor - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
      hl_mode = "combine",
    })
  end
  M.mark_deletes(buf, hunk)
end

---@param buf integer
---@param hunks table[]
function M.apply(buf, hunks)
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  for _, hunk in ipairs(hunks or {}) do
    M.apply_hunk(buf, hunk)
  end
end

---@param buf integer
function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
end

return M
