-- busted specs for codex_workbench.error_codes
--
-- Run via: nvim --headless -u tests/minimal_init.lua
--          -c "PlenaryBustedFile tests/spec/error_codes_spec.lua" +q

local error_codes = require("codex_workbench.error_codes")

describe("error_codes.messages", function()
  local all_codes = {
    "not_initialized",
    "invalid_request",
    "unknown_method",
    "not_a_git_repository",
    "git_failed",
    "patch_apply_failed",
    "scope_invalid",
    "scope_file_not_found",
    "scope_hunk_not_found",
    "no_pending_review",
    "review_pending",
    "real_workspace_changed",
    "app_server_crashed",
    "app_server_error",
    "turn_failed",
    "no_thread",
    "io_error",
    "internal_error",
    -- Phase 2
    "state_unavailable",
    "workspace_locked",
    "shadow_unavailable",
  }

  for _, code in ipairs(all_codes) do
    it("has a string message for " .. code, function()
      assert.is_string(error_codes.messages[code],
        "messages[" .. code .. "] should be a string, got: " .. type(error_codes.messages[code]))
      assert.is_true(#error_codes.messages[code] > 0,
        "messages[" .. code .. "] must not be empty")
    end)
  end
end)

describe("error_codes.format", function()
  it("returns the localized message for a known error_code", function()
    local resp = { ok = false, error_code = "patch_apply_failed", error = "raw" }
    local result = error_codes.format(resp)
    assert.equals(error_codes.messages.patch_apply_failed, result)
  end)

  it("falls back to the raw error when error_code is absent", function()
    local resp = { ok = false, error = "raw fallback message" }
    assert.equals("raw fallback message", error_codes.format(resp))
  end)

  it("falls back to the raw error when error_code is unrecognized", function()
    local resp = { ok = false, error_code = "totally_unknown_code_xyz", error = "raw" }
    assert.equals("raw", error_codes.format(resp))
  end)

  it("truncates very long fallback messages", function()
    local long_msg = string.rep("x", 500)
    local resp = { ok = false, error = long_msg }
    local result = error_codes.format(resp)
    assert.is_true(#result <= 205, "formatted result should be capped at 205 chars, got " .. #result)
  end)

  it("returns empty string for a nil error field", function()
    local resp = { ok = false }
    local result = error_codes.format(resp)
    -- Should not raise an error; result may be empty string or nil-safe
    assert.is_not_nil(result)
  end)
end)
