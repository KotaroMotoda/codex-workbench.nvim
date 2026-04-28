local M = {}

---@class CodexWorkbenchBinaryOpts
---@field auto_install boolean Automatically install the bridge binary if missing (default: false)
---@field path string|nil Explicit path to the bridge binary; overrides auto-discovery

---@class CodexWorkbenchOutputOpts
---@field position "right"|"bottom" Split direction for the output window (default: "right")
---@field size integer Column or row count for the output window (default: 40)
---@field winbar boolean Show key hints in the output winbar (default: true)

---@class CodexWorkbenchReviewOpts
---@field layout "vertical"|"horizontal" Split direction for the review window (default: "vertical")
---@field mode "split"|"diffview" Review UI mode (default: "split")
---@field tree_width integer Width of the file tree pane in diffview mode (default: 30)
---@field winbar boolean Show key hints in review winbars (default: true)

---@class CodexWorkbenchProgressOpts
---@field enabled boolean Show progress toast (default: true)
---@field position "bottom_right"|"top_right"|"off" Progress toast position (default: "bottom_right")

---@class CodexWorkbenchInlineOpts
---@field enabled boolean Show small reviews inline in target buffers (default: true)
---@field prefix string Buffer-local keymap prefix (default: "<leader>c")
---@field jump { next: string, prev: string } Hunk navigation maps
---@field auto_show boolean Automatically show inline review after ask completes (default: true)
---@field fallback_to_review boolean Open review buffer for large or unsafe reviews (default: true)
---@field fallback_threshold integer Max file count for inline display (default: 3)

---@class CodexWorkbenchErrorOpts
---@field interactive boolean Prompt follow-up actions for actionable errors (default: true)

---@class CodexWorkbenchContextsEnabled
---@field this boolean Replace @this with current file and nearby lines (default: true)
---@field buffer boolean Replace @buffer with the current buffer's text (default: true)
---@field selection boolean Replace @selection with the visual selection (default: true)
---@field diagnostics boolean Replace @diagnostics with LSP diagnostics (default: true)
---@field changes boolean Replace @changes with git diff of the current file (default: true)
---@field file boolean Replace @file(path) with the file's contents (default: true)

---@class CodexWorkbenchOpts
---@field codex_cmd string Command to invoke the Codex CLI (default: "codex")
---@field binary CodexWorkbenchBinaryOpts
---@field ui { output: CodexWorkbenchOutputOpts, review: CodexWorkbenchReviewOpts, progress: CodexWorkbenchProgressOpts, inline: CodexWorkbenchInlineOpts }
---@field errors CodexWorkbenchErrorOpts
---@field session { auto_resume: boolean } auto_resume: initialize bridge on startup (default: true)
---@field shadow { root: string, max_untracked_file_bytes: integer, max_untracked_total_bytes: integer }
---@field contexts { enabled: CodexWorkbenchContextsEnabled }
---@field statusline { enabled: boolean }

M.defaults = {
  codex_cmd = "codex",
  binary = {
    auto_install = false,
    path = nil,
  },
  ui = {
    output = {
      position = "right",
      size = 40,
      winbar = true,
    },
    review = {
      layout = "vertical",
      mode = "split",
      tree_width = 30,
      winbar = true,
    },
    progress = {
      enabled = true,
      position = "bottom_right",
    },
    inline = {
      enabled = true,
      prefix = "<leader>c",
      jump = { next = "]c", prev = "[c" },
      auto_show = true,
      fallback_to_review = true,
      fallback_threshold = 3,
    },
  },
  errors = {
    interactive = true,
  },
  session = {
    auto_resume = true,
  },
  shadow = {
    root = vim.fn.stdpath("state") .. "/codex-workbench/shadows",
    max_untracked_file_bytes = 5242880,
    max_untracked_total_bytes = 52428800,
  },
  contexts = {
    enabled = {
      this = true,
      buffer = true,
      selection = true,
      diagnostics = true,
      changes = true,
      file = true,
    },
  },
  statusline = {
    enabled = true,
  },
}

---@param opts CodexWorkbenchOpts|nil
---@return CodexWorkbenchOpts
function M.setup(opts)
  return vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
