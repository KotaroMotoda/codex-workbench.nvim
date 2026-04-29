local M = {}

function M.attach(chat, buf, opts)
  vim.keymap.set("i", "<C-CR>", function()
    chat.submit()
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<C-CR>", function()
    chat.submit()
  end, { buffer = buf, silent = true })
  if opts.enter_submits ~= false then
    vim.keymap.set("i", "<CR>", function()
      chat.submit()
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "<CR>", function()
      chat.submit()
    end, { buffer = buf, silent = true })
  end
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    chat.cancel()
  end, { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-l>", function()
    chat.clear()
  end, { buffer = buf, silent = true })
end

return M
