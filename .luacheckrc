-- Neovim runtime globals
globals = { "vim" }

-- busted test framework globals (inject into test files only)
files["tests/**/*.lua"] = {
  globals = {
    "describe",
    "it",
    "before_each",
    "after_each",
    "assert",
    "pending",
    "spy",
    "mock",
    "stub",
  },
}

max_line_length = false
-- Allow unused function arguments (common with bridge callbacks)
unused_args = false
