-- Minimal Neovim init for running plenary/busted specs.
--
-- Usage (CI):
--   git clone https://github.com/nvim-lua/plenary.nvim \
--       ~/.local/share/nvim/site/pack/testing/start/plenary.nvim
--   nvim --headless -u tests/minimal_init.lua \
--       -c "PlenaryBustedDirectory tests/spec/ { minimal_init = 'tests/minimal_init.lua' }" \
--       +q

-- Add plenary from the pack path installed by the CI step.
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/site/pack/testing/start/plenary.nvim"))

-- Add the plugin root so `require("codex_workbench.*")` resolves correctly.
vim.opt.rtp:prepend(vim.fn.getcwd())
