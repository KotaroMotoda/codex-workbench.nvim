local M = {}

function M.request(message, callback)
  local method = message.method or "approval"
  local choices = {
    { label = "Approve", value = "approved" },
    { label = "Deny", value = "denied" },
    { label = "Abort", value = "abort" },
  }
  vim.ui.select(choices, {
    prompt = "Codex approval: " .. method,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    callback((choice and choice.value) or "denied")
  end)
end

return M
