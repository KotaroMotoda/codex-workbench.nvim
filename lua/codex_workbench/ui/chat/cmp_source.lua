local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { "@" }
end

function source:get_keyword_pattern()
  return [[@\w*]]
end

function source:complete(_, callback)
  local enabled = vim.tbl_deep_extend("force", {}, require("codex_workbench.config").defaults.contexts.enabled)
  local runtime = require("codex_workbench").opts
  if runtime and runtime.contexts and runtime.contexts.enabled then
    enabled = vim.tbl_deep_extend("force", enabled, runtime.contexts.enabled)
  end

  local items = {}
  local function add(flag, label, documentation)
    if enabled[flag] then
      table.insert(items, { label = label, documentation = documentation })
    end
  end

  add("this", "@this", "現在のカーソル位置 (file:line)")
  add("buffer", "@buffer", "現在のバッファ全文")
  add("selection", "@selection", "ビジュアル選択範囲")
  add("diagnostics", "@diagnostics", "LSP 診断")
  add("changes", "@changes", "現ファイルの git diff")
  add("file", "@file(", "@file(path) - 任意ファイル")

  callback({ items = items, isIncomplete = false })
end

return source
