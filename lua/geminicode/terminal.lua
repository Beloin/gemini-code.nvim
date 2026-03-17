--- Terminal module for gemini-code.nvim
-- Spawns the `gemini` CLI process in a Neovim terminal buffer with the
-- required environment variables for IDE integration.
--
-- Supports two providers:
--   - snacks  (folke/snacks.nvim)  — preferred when available
--   - native  (built-in :terminal) — fallback
--
-- Provider is selected based on config.terminal.provider:
--   "auto"   → snacks if available, otherwise native
--   "snacks" → always use snacks (errors if not installed)
--   "native" → always use native terminal
-- @module geminicode.terminal

local log = require("geminicode.log")
local tcp = require("geminicode.server.tcp")

local M = {}

--- @type integer|nil  Buffer number of the terminal
local term_bufnr = nil

--- @type integer|nil  Window ID of the terminal window (if currently visible)
local term_winid = nil

--- @type table  Active configuration (merged from defaults + user config)
local config = {}

--- Detect whether snacks.nvim is available.
-- @return boolean
local function has_snacks()
  return pcall(require, "snacks")
end

--- Build the environment table to inject into the terminal.
-- @return table  Key-value pairs for the spawned process
local function build_env()
  local port = tcp.get_port()
  if not port then
    log.warn("Terminal: server port not available yet")
  end
  return {
    GEMINI_CLI_IDE_SERVER_PORT = port and tostring(port) or "",
  }
end

--- Build the shell command string that launches the CLI.
-- Prepends environment variable assignments so they're visible to the process
-- regardless of shell.
-- @param args string|nil  Optional arguments to pass to the CLI (e.g. "--approval-mode=auto_edit")
-- @return string
local function build_cmd(args)
  local env  = build_env()
  local env_prefix = ""
  for k, v in pairs(env) do
    env_prefix = env_prefix .. k .. "=" .. v .. " "
  end
  -- Always pass --ide so Gemini CLI activates IDE companion mode and connects
  -- back to the MCP server we started.
  local cmd = (config.terminal_cmd or "gemini") .. " --ide"
  if args and args ~= "" then
    cmd = cmd .. " " .. args
  end
  return env_prefix .. cmd
end

--- Return the width (in columns) for the terminal split.
-- @return integer
local function split_width()
  local pct = config.terminal and config.terminal.split_width_percentage or 0.35
  return math.floor(vim.o.columns * pct)
end

--- Open a vertical split on the configured side and switch to it.
local function open_split()
  local side = (config.terminal and config.terminal.split_side) or "right"
  if side == "right" then
    vim.cmd("botright vsplit")
  else
    vim.cmd("topleft vsplit")
  end
  -- Resize to configured width
  vim.api.nvim_win_set_width(0, split_width())
end

--- Open the terminal using the native :terminal provider.
-- @param args string|nil  Optional CLI arguments
local function open_native(args)
  open_split()
  local cmd = build_cmd(args)
  vim.cmd("terminal " .. cmd)

  term_bufnr = vim.api.nvim_get_current_buf()
  term_winid = vim.api.nvim_get_current_win()

  -- Set a friendly name
  vim.api.nvim_buf_set_name(term_bufnr, "gemini")

  -- Auto-close: delete buffer when process exits
  if config.terminal and config.terminal.auto_close then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = term_bufnr,
      once   = true,
      callback = function()
        if term_bufnr and vim.api.nvim_buf_is_valid(term_bufnr) then
          vim.api.nvim_buf_delete(term_bufnr, { force = true })
        end
        term_bufnr = nil
        term_winid = nil
        log.info("Gemini terminal closed")
      end,
    })
  end

  -- Enter terminal mode immediately
  vim.cmd("startinsert")
  log.info("Gemini terminal opened (native) on port", tcp.get_port())
end

--- Open the terminal using snacks.nvim.
-- @param args string|nil  Optional CLI arguments
local function open_snacks(args)
  local snacks = require("snacks")
  local cmd    = build_cmd(args)

  -- snacks.terminal.open() creates or toggles a terminal
  snacks.terminal.open(cmd, {
    win = {
      position = (config.terminal and config.terminal.split_side == "left") and "left" or "right",
      width    = (config.terminal and config.terminal.split_width_percentage) or 0.35,
    },
  })

  -- Try to capture the buffer number after snacks opens it
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(bufnr, "buftype") == "terminal" then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:find("gemini") then
          term_bufnr = bufnr
          break
        end
      end
    end
    log.info("Gemini terminal opened (snacks) on port", tcp.get_port())
  end)
end

--- Open the terminal window if it is not already visible.
local function show_window()
  if not term_bufnr or not vim.api.nvim_buf_is_valid(term_bufnr) then
    return false
  end
  -- Check if already visible
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(winid) == term_bufnr then
      term_winid = winid
      return true
    end
  end
  -- Re-open a split showing the existing terminal buffer
  open_split()
  vim.api.nvim_set_current_buf(term_bufnr)
  term_winid = vim.api.nvim_get_current_win()
  vim.cmd("startinsert")
  return true
end

--- Hide the terminal window without closing it.
local function hide_window()
  if term_winid and vim.api.nvim_win_is_valid(term_winid) then
    vim.api.nvim_win_close(term_winid, false)
    term_winid = nil
  end
end

--- Configure the terminal module.
-- @param cfg table  Full geminicode config (from config.lua)
function M.setup(cfg)
  config = cfg or {}
end

--- Toggle the Gemini terminal.
-- If closed: open it and spawn `gemini`.
-- If open and focused: hide it.
-- If open but not focused: focus it.
-- @param args string|nil  Optional CLI arguments (e.g. "--approval-mode=auto_edit")
function M.toggle(args)
  -- Case 1: no terminal yet → spawn it
  if not term_bufnr or not vim.api.nvim_buf_is_valid(term_bufnr) then
    term_bufnr = nil
    term_winid = nil

    local provider = (config.terminal and config.terminal.provider) or "auto"
    if provider == "snacks" or (provider == "auto" and has_snacks()) then
      open_snacks(args)
    else
      open_native(args)
    end
    return
  end

  -- Case 2: terminal exists, check window visibility
  local visible_winid = nil
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(winid) == term_bufnr then
      visible_winid = winid
      break
    end
  end

  if visible_winid then
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == visible_winid then
      -- Currently focused → hide
      hide_window()
    else
      -- Visible but not focused → focus
      vim.api.nvim_set_current_win(visible_winid)
      vim.cmd("startinsert")
    end
  else
    -- Not visible → show
    show_window()
    vim.cmd("startinsert")
  end
end

--- Focus the terminal (open if needed, always go to terminal mode).
function M.focus()
  if not term_bufnr or not vim.api.nvim_buf_is_valid(term_bufnr) then
    M.toggle()
    return
  end
  if not show_window() then
    M.toggle()
    return
  end
  vim.cmd("startinsert")
end

--- Send text to the terminal (e.g., a selected region as Gemini context).
-- @param text string  Text to paste into the terminal
function M.send(text)
  if not term_bufnr or not vim.api.nvim_buf_is_valid(term_bufnr) then
    log.warn("Cannot send text: Gemini terminal is not open")
    return
  end
  local channel = vim.api.nvim_buf_get_var(term_bufnr, "terminal_job_id")
  if channel then
    vim.fn.chansend(channel, text)
  end
end

--- Return whether the terminal buffer is currently open.
-- @return boolean
function M.is_open()
  return term_bufnr ~= nil and vim.api.nvim_buf_is_valid(term_bufnr)
end

--- Close and wipe the terminal buffer.
function M.close()
  if term_bufnr and vim.api.nvim_buf_is_valid(term_bufnr) then
    vim.api.nvim_buf_delete(term_bufnr, { force = true })
  end
  term_bufnr = nil
  term_winid = nil
end

return M
