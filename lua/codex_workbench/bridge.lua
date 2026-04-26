local output = require("codex_workbench.ui.output")
local review = require("codex_workbench.ui.review")
local approval = require("codex_workbench.ui.approval")
local log = require("codex_workbench.log")

local M = {
  job_id = nil,
  next_id = 1,
  callbacks = {},
  init_callbacks = {},
  initializing = false,
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

  local installed = vim.fn.stdpath("data") .. "/codex-workbench/bin/0.1.0/codex-workbench-bridge"
  if vim.fn.executable(installed) == 1 then
    return installed
  end

  local dev = plugin_root() .. "/rust/target/debug/codex-workbench-bridge"
  if vim.fn.executable(dev) == 1 then
    return dev
  end

  return "codex-workbench-bridge"
end

local function notify_error(message)
  log.write("ERROR", message)
  vim.schedule(function()
    vim.notify(message .. "\nLog: " .. log.path(), vim.log.levels.ERROR, { title = "codex-workbench" })
  end)
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
    notify_error(message.message or "unknown bridge error")
  end
end

local function handle_message(line)
  if line == "" then
    return
  end
  local ok, message = pcall(vim.json.decode, line)
  if not ok then
    log.write("ERROR", "invalid bridge JSON", line)
    notify_error("bridge returned invalid JSON")
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

local function on_stdout(_, data)
  for _, line in ipairs(data or {}) do
    handle_message(line)
  end
end

local function on_stderr(_, data)
  for _, line in ipairs(data or {}) do
    if line ~= "" then
      notify_error(line)
    end
  end
end

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
      notify_error(result.stderr ~= "" and result.stderr or "binary install failed")
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
      M.job_id = nil
      M.initializing = false
      M.state.initialized = false
      M.state.phase = "idle"
      if code ~= 0 and code ~= 130 and code ~= 143 then
        notify_error("bridge exited with code " .. tostring(code))
      end
    end,
  })

  if M.job_id <= 0 then
    notify_error("failed to start bridge: " .. bin)
    return false
  end

  return true
end

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
      notify_error(response.error or "bridge initialization failed")
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

function M.request(method, params, callback)
  if not M.job_id then
    notify_error("bridge is not running")
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
