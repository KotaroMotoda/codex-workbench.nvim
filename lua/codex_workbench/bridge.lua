local output = require("codex_workbench.ui.output")
local review = require("codex_workbench.ui.review")
local approval = require("codex_workbench.ui.approval")
local log = require("codex_workbench.log")
local error_codes = require("codex_workbench.error_codes")

local M = {
  job_id = nil,
  next_id = 1,
  callbacks = {},
  init_callbacks = {},
  initializing = false,
  stdout_pending = "",
  stderr_pending = "",
  state = {
    initialized = false,
    phase = "idle",
    pending_review = nil,
    thread_id = nil,
    shadow_path = nil,
  },
}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local function executable(opts)
  if opts.binary and opts.binary.path then
    return opts.binary.path
  end

  -- Prefer the newest installed release, sorted numerically by semver so that
  -- 0.10.0 correctly sorts after 0.9.0.
  local pattern = vim.fn.stdpath("data") .. "/codex-workbench/bin/*/codex-workbench-bridge"
  local matches = vim.fn.glob(pattern, false, true)
  if matches and #matches > 0 then
    local function semver(p)
      local v = p:match("/(%d+%.%d+%.%d+)/codex%-workbench%-bridge$") or "0.0.0"
      local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
      return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
    end
    table.sort(matches, function(x, y)
      local vx, vy = semver(x), semver(y)
      for i = 1, 3 do
        if vx[i] ~= vy[i] then return vx[i] < vy[i] end
      end
      return false
    end)
    local installed = matches[#matches]
    if vim.fn.executable(installed) == 1 then
      return installed
    end
  end

  local dev = plugin_root() .. "/rust/target/debug/codex-workbench-bridge"
  if vim.fn.executable(dev) == 1 then
    return dev
  end

  return "codex-workbench-bridge"
end

--- Notify the user about a fatal bridge condition. Accepts either a structured
--- bridge response, a `{ code, message, details }` event payload, or a plain
--- string. The full payload is always written to the log; the popup only ever
--- shows the localized one-liner so we never leak large stderr blobs.
local function notify_error(payload)
  log.write("ERROR", "bridge_error", payload)
  local message = error_codes.format(payload)
  vim.schedule(function()
    vim.notify(
      message .. "\nLog: " .. log.path(),
      vim.log.levels.ERROR,
      { title = "codex-workbench" }
    )
  end)
end

--- Lighter-weight log write for non-fatal bridge output (stderr lines, etc.).
local function log_warn(message)
  if message == nil or message == "" then
    return
  end
  log.write("WARN", "bridge_stderr", message)
end

local function handle_event(message)
  if message.event == "ready" then
    M.state.initialized = true
    M.state.phase = "ready"
    M.state.shadow_path = message.shadow_path
    M.state.thread_id = message.state and message.state.thread_id or nil
  elseif message.event == "turn_started" then
    M.state.phase = "running"
    M.state.thread_id = message.thread_id or M.state.thread_id
  elseif message.event == "turn_completed" then
    M.state.phase = "ready"
    output.finish_turn(message)
  elseif message.event == "thread_started" then
    M.state.thread_id = message.thread_id or M.state.thread_id
  elseif message.event == "output_delta" then
    output.append(message.text or "")
  elseif message.event == "message_completed" then
    output.set_final(message.text or "")
  elseif message.event == "diff_preview" then
    output.set_diff_preview(message.diff or "")
  elseif message.event == "review_created" then
    M.state.phase = "review"
    M.state.pending_review = message.item
    review.open(message.item)
  elseif message.event == "review_state" then
    local pending = message.pending
    M.state.phase = pending and "review" or "ready"
    M.state.pending_review = pending
    review.render(pending)
  elseif message.event == "approval_request" then
    log.write("INFO", "approval_request", message)
    approval.request(message, function(decision)
      M.request("approval_response", {
        approval_id = message.approval_id,
        decision = decision,
      })
    end)
  elseif message.event == "shadow_warning" then
    log.write("WARN", "shadow_warning", message)
    vim.schedule(function()
      vim.notify(message.path .. ": " .. message.reason, vim.log.levels.WARN, { title = "codex-workbench" })
    end)
  elseif message.event == "appserver_event" then
    output.handle_appserver_event(message.method, message.summary)
  elseif message.event == "turn_error" then
    M.state.phase = "ready"
    log.write("ERROR", "turn_error", message)
    output.show_error(message.message or "Codex turn failed")
  elseif message.event == "error" then
    notify_error(message)
  end
end

local function handle_message(line)
  if line == "" then
    return
  end
  local ok, message = pcall(vim.json.decode, line)
  if not ok then
    log.write("ERROR", "invalid_bridge_json", line)
    notify_error({ code = "internal_error" })
    return
  end

  if message.id and M.callbacks[message.id] then
    local callback = M.callbacks[message.id]
    M.callbacks[message.id] = nil
    vim.schedule(function()
      callback(message)
    end)
    return
  end

  if message.event then
    if message.event ~= "output_delta" and message.event ~= "diff_preview" then
      log.write("DEBUG", "bridge_event:" .. message.event, message)
    end
    vim.schedule(function()
      handle_event(message)
    end)
  end
end

local function consume_lines(data, pending, line_handler)
  if not data or #data == 0 then
    return pending
  end

  for index, chunk in ipairs(data) do
    local line = chunk
    if index == 1 then
      line = pending .. line
    end

    if index == #data then
      pending = line
    else
      line_handler(line)
    end
  end

  return pending
end

local function on_stdout(_, data)
  M.stdout_pending = consume_lines(data, M.stdout_pending, function(line)
    handle_message(line)
  end)
end

local function on_stderr(_, data)
  -- The Rust bridge only uses stderr for diagnostic logging. We surface those
  -- lines in the workbench log so users can find them when debugging, but we
  -- never promote them to a notification: that path used to flood the user
  -- with raw error fragments and leak internal payloads.
  M.stderr_pending = consume_lines(data, M.stderr_pending, log_warn)
end

---@param opts table
---@return boolean
function M.start(opts)
  if M.job_id and vim.fn.jobwait({ M.job_id }, 0)[1] == -1 then
    return true
  end

  local bin = executable(opts)
  if vim.fn.executable(bin) == 0 and opts.binary and opts.binary.auto_install then
    local script = plugin_root() .. "/scripts/install_binary.sh"
    local result = vim.system({ script }, { text = true }):wait()
    if result.code == 0 then
      bin = vim.trim(result.stdout or "")
    else
      log.write("ERROR", "binary_install_failed", result.stderr or "")
      notify_error({ code = "internal_error" })
      return false
    end
  end

  M.job_id = vim.fn.jobstart({ bin }, {
    cwd = plugin_root(),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = function(_, code)
      if M.stdout_pending ~= "" then
        handle_message(M.stdout_pending)
        M.stdout_pending = ""
      end
      if M.stderr_pending ~= "" then
        log_warn(M.stderr_pending)
        M.stderr_pending = ""
      end
      -- Flush any in-flight request callbacks so callers don't hang forever.
      -- Deliver a synthetic crash error rather than leaving them pending.
      local crashed = { ok = false, error_code = "app_server_crashed" }
      for _, cb in pairs(M.callbacks) do
        pcall(cb, crashed)
      end
      M.callbacks = {}
      M.next_id = 1
      M.job_id = nil
      M.initializing = false
      M.state.initialized = false
      M.state.phase = "idle"
      if code ~= 0 and code ~= 130 and code ~= 143 then
        notify_error({ code = "app_server_crashed", details = { exit_code = code } })
      end
    end,
  })

  if M.job_id <= 0 then
    log.write("ERROR", "bridge_start_failed", { binary = bin })
    notify_error({ code = "app_server_crashed" })
    return false
  end

  return true
end

---@param opts table
---@param callback function|nil
function M.initialize(opts, callback)
  if M.state.initialized then
    if callback then
      vim.schedule(function()
        callback({ ok = true, result = M.state })
      end)
    end
    return
  end

  if not M.start(opts) then
    return
  end

  callback = callback or function(response)
    if not response.ok then
      notify_error(response)
    end
  end

  table.insert(M.init_callbacks, callback)
  if M.initializing then
    return
  end
  M.initializing = true

  M.request("initialize", {
    workspace = vim.uv.cwd(),
    state_dir = vim.fn.stdpath("state") .. "/codex-workbench",
    shadow_root = opts.shadow.root,
    codex_cmd = opts.codex_cmd,
    max_untracked_file_bytes = opts.shadow.max_untracked_file_bytes,
    max_untracked_total_bytes = opts.shadow.max_untracked_total_bytes,
  }, function(response)
    M.initializing = false
    if response.ok then
      M.state.initialized = true
      M.state.phase = "ready"
      if response.result then
        M.state.pending_review = response.result.pending_review
        M.state.thread_id = response.result.thread_id
        M.state.shadow_path = response.result.shadow_path
      end
    end
    local callbacks = M.init_callbacks
    M.init_callbacks = {}
    for _, cb in ipairs(callbacks) do
      cb(response)
    end
  end)
end

---@param method string
---@param params table|nil
---@param callback function|nil
function M.request(method, params, callback)
  if not M.job_id then
    notify_error({ code = "not_initialized" })
    return
  end

  local id = callback and M.next_id or nil
  if id then
    M.next_id = M.next_id + 1
    M.callbacks[id] = callback
  end

  local payload = {
    id = id,
    method = method,
    params = params or {},
  }
  vim.fn.chansend(M.job_id, vim.json.encode(payload) .. "\n")
end

return M
