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
---@field pane_split integer Before/after pane ratio in diffview mode (default: 50)
---@field ascii_only boolean Use ASCII-only review symbols (default: false)
---@field winbar boolean Show key hints in review winbars (default: true)
---@field signs boolean Show extmark signs in review panes (default: true)
---@field badges boolean Show hunk badges in review tree (default: true)
---@field ascii_only boolean Use ASCII review symbols in badges (default: false)

---@class CodexWorkbenchProgressOpts
---@field enabled boolean Show progress toast (default: true)
---@field position "bottom_right"|"top_right"|"off" Progress toast position (default: "bottom_right")
---@field ascii_only boolean Use ASCII spinner frames (default: false)
---@field fade_ms integer Milliseconds to keep done/error messages visible (default: 1500)

---@class CodexWorkbenchChatOpts
---@field enabled boolean Enable chat UI command (default: true)
---@field position "right"|"tab" Chat UI placement (default: "right")
---@field width integer Chat columns when position="right" (default: 100)
---@field threads_width integer Thread sidebar columns (default: 30)
---@field prompt_height integer Prompt split height (default: 5)
---@field enter_submits boolean Submit with <CR> in prompt buffer (default: true)
---@field cmp_source boolean Register nvim-cmp source when available (default: true)

---@class CodexWorkbenchInlineOpts
---@field enabled boolean Show small reviews inline in target buffers (default: true)
---@field prefix string Buffer-local keymap prefix (default: "<leader>c")
---@field jump { next: string, prev: string } Hunk navigation maps
---@field auto_show boolean Automatically show inline review after ask completes (default: true)
---@field fallback_to_review boolean Open review buffer for large or unsafe reviews (default: true)
---@field fallback_threshold integer Max file count for inline display (default: 3)

---@class CodexWorkbenchErrorOpts
---@field interactive boolean Prompt follow-up actions for actionable errors (default: true)
---@field show_log_path boolean Include the log path in error notifications and prompts (default: true)

---@class CodexWorkbenchPaletteHistoryOpts
---@field enabled boolean Include recent prompts from the bridge state (default: true)
---@field limit integer Maximum prompt history entries to show (default: 50)

---@class CodexWorkbenchPaletteOpts
---@field enabled boolean Enable palette command/keymap (default: true)
---@field keymap string|false Normal-mode keymap for the palette (default: "<leader>cp")
---@field templates table[] User slash prompt templates; matching triggers override built-ins
---@field history CodexWorkbenchPaletteHistoryOpts

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
---@field ui { output: CodexWorkbenchOutputOpts, review: CodexWorkbenchReviewOpts, progress: CodexWorkbenchProgressOpts, chat: CodexWorkbenchChatOpts, inline: CodexWorkbenchInlineOpts, palette: CodexWorkbenchPaletteOpts }
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
      pane_split = 50,
      ascii_only = false,
      winbar = true,
      signs = true,
      badges = true,
    },
    progress = {
      enabled = true,
      position = "bottom_right",
      ascii_only = false,
      fade_ms = 1500,
    },
    chat = {
      enabled = true,
      position = "right",
      width = 100,
      threads_width = 30,
      prompt_height = 5,
      enter_submits = true,
      cmp_source = true,
    },
    inline = {
      enabled = true,
      prefix = "<leader>c",
      jump = { next = "]c", prev = "[c" },
      auto_show = true,
      fallback_to_review = true,
      fallback_threshold = 3,
    },
    palette = {
      enabled = true,
      keymap = "<leader>cp",
      templates = {},
      history = {
        enabled = true,
        limit = 50,
      },
    },
  },
  errors = {
    interactive = true,
    show_log_path = true,
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
  M.current = vim.tbl_deep_extend("force", M.defaults, opts or {})
  return M.current
end

return M
