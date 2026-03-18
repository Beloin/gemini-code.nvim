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

  -- 6. Register default keymaps
  vim.keymap.set("v", "<leader>ags", ":<C-u>GeminiCodeSend<CR>", {
    desc = "Send file reference for selection to Gemini",
  })
  vim.keymap.set("n", "<leader>agb", "<cmd>GeminiCodeSendBuffer<CR>", {
    desc = "Send file reference for current buffer to Gemini",
  })
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

--- Toggle the Gemini CLI terminal in resume mode.
-- Passes --resume to the CLI to resume the last conversation.
function M.toggle_terminal_resume()
  require("geminicode.terminal").toggle("--resume")
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

--- Send a file reference for the current visual selection to the Gemini terminal.
--- Sends @file#Lstart-end (Gemini CLI syntax) so the CLI resolves the content.
function M.send_selection()
  local log      = require("geminicode.log")
  local terminal = require("geminicode.terminal")

  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    log.warn("Cannot send selection: buffer has no file")
    return
  end

  local start_line = vim.fn.getpos("'<")[2]
  local end_line   = vim.fn.getpos("'>")[2]
  if start_line == 0 or end_line == 0 then
    log.warn("No selection to send")
    return
  end

  local rel_path = vim.fn.fnamemodify(bufname, ":.")
  local ref
  if start_line == end_line then
    ref = "@" .. rel_path .. "#L" .. start_line
  else
    ref = "@" .. rel_path .. "#L" .. start_line .. "-" .. end_line
  end

  terminal.focus()
  terminal.send(ref .. " ")
end

--- Send a file reference for the current buffer to the Gemini terminal.
--- Sends @file (Gemini CLI syntax) so the CLI can read the whole file.
function M.send_buffer()
  local log      = require("geminicode.log")
  local terminal = require("geminicode.terminal")

  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    log.warn("Cannot send buffer: buffer has no file")
    return
  end

  local rel_path = vim.fn.fnamemodify(bufname, ":.")
  local ref = "@" .. rel_path

  terminal.focus()
  terminal.send(ref .. " ")
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
