--- Main public API for gemini-code.nvim
-- Entry point for plugin consumers.  Call M.setup() from your Neovim config.
-- @module geminicode

local M = {}

--- @type boolean  Whether setup() has been called
local _initialized = false

--- @type boolean  Whether the server is currently running
local _running = false

--- Set up the plugin with optional user configuration.
-- This is the only function users need to call from their Neovim config.
-- @param user_config table|nil  Optional overrides for defaults
function M.setup(user_config)
  if _initialized then
    require("geminicode.log").warn("geminicode.setup() called more than once — ignoring")
    return
  end
  _initialized = true

  -- 1. Load and validate config
  local config = require("geminicode.config")
  config.setup(user_config)
  local opts = config.options

  -- 2. Configure logger
  local log = require("geminicode.log")
  log.set_level(opts.log_level)

  -- 3. Configure submodules
  require("geminicode.diff").setup(opts.diff_opts)
  require("geminicode.terminal").setup(opts)

  -- 4. Register MCP tools
  require("geminicode.tools").setup()

  -- 5. Auto-start if configured
  if opts.auto_start then
    M.start()
  end
end

--- Start the MCP HTTP server and create the discovery file.
function M.start()
  if _running then
    require("geminicode.log").warn("geminicode: already running")
    return
  end

  local log        = require("geminicode.log")
  local server     = require("geminicode.server")
  local discovery  = require("geminicode.discovery")
  local context    = require("geminicode.context")
  local config_mod = require("geminicode.config")
  local opts       = config_mod.options

  -- Start HTTP server
  local ok, err = server.start()
  if not ok then
    log.error("Failed to start MCP server:", err)
    return
  end

  -- Create discovery file so the CLI can find us
  local disc_ok, disc_err = discovery.create(server.get_port(), opts.ide_info)
  if not disc_ok then
    log.error("Failed to create discovery file:", disc_err)
  end

  -- Start context tracking
  context.start(opts.context)

  _running = true
  log.info("gemini-code.nvim started (port " .. tostring(server.get_port()) .. ")")
end

--- Stop the MCP server and clean up.
function M.stop()
  if not _running then
    return
  end

  local log       = require("geminicode.log")
  local server    = require("geminicode.server")
  local discovery = require("geminicode.discovery")
  local context   = require("geminicode.context")

  context.stop()
  discovery.delete()
  server.stop()

  _running = false
  log.info("gemini-code.nvim stopped")
end

--- Toggle the Gemini CLI terminal.
-- @param args string|nil  Optional CLI arguments
function M.toggle_terminal(args)
  require("geminicode.terminal").toggle(args)
end

--- Toggle the Gemini CLI terminal with auto-edit mode enabled.
-- Passes --approval-mode=auto_edit to the CLI (skips diff approval).
function M.toggle_terminal_auto_edit()
  require("geminicode.terminal").toggle("--approval-mode=auto_edit")
end

--- Focus (or open) the Gemini CLI terminal.
function M.focus_terminal()
  require("geminicode.terminal").focus()
end

--- Manually add a file to the IDE context sent to the CLI.
-- @param path string|nil  Absolute path; defaults to the current buffer
function M.add_file(path)
  path = path or vim.api.nvim_buf_get_name(0)
  require("geminicode.context").add_file(path)
end

--- Send the current visual selection to the Gemini terminal as context.
function M.send_selection()
  -- Get selected text
  local start_pos = vim.fn.getpos("'<")
  local end_pos   = vim.fn.getpos("'>")
  local lines     = vim.api.nvim_buf_get_lines(
    0, start_pos[2] - 1, end_pos[2], false
  )
  if #lines == 0 then
    require("geminicode.log").warn("No selection to send")
    return
  end
  local text = table.concat(lines, "\n")
  require("geminicode.terminal").send(text .. "\n")
end

--- Accept the active diff in the current buffer.
function M.diff_accept()
  require("geminicode.diff").accept()
end

--- Reject the active diff in the current buffer.
function M.diff_reject()
  require("geminicode.diff").reject()
end

--- Return whether the plugin is currently running.
-- @return boolean
function M.is_running()
  return _running
end

return M
