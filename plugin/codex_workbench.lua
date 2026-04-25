if vim.g.loaded_codex_workbench == 1 then
  return
end
vim.g.loaded_codex_workbench = 1

vim.api.nvim_create_user_command("CodexWorkbenchSetup", function()
  require("codex_workbench").setup({})
end, {})

