--- Discovery file module for gemini-code.nvim
-- Creates and removes the JSON file that the Gemini CLI uses to discover the
-- IDE companion server.
--
-- File location: {os.tmpdir}/gemini/ide/gemini-ide-server-{PID}-{PORT}.json
-- @module geminicode.discovery

local log  = require("geminicode.log")
local auth = require("geminicode.server.auth")

local M = {}

--- @type string|nil  Path to the currently active discovery file
local discovery_file_path = nil

--- Return the directory where discovery files are stored.
-- @return string
local function discovery_dir()
  return vim.loop.os_tmpdir() .. "/gemini/ide"
end

--- Build the discovery file path for the current PID and port.
-- @param port integer
-- @return string
local function build_path(port)
  local pid = vim.fn.getpid()
  return discovery_dir() .. "/gemini-ide-server-" .. tostring(pid) .. "-" .. tostring(port) .. ".json"
end

--- Create the discovery file.
-- Must be called after the TCP server is bound and the auth token is generated.
--
-- @param port integer            Listening port
-- @param ide_info table          { name, display_name } from config
-- @return boolean, string|nil    success, error message
function M.create(port, ide_info)
  -- Ensure the directory exists
  local dir = discovery_dir()
  vim.fn.mkdir(dir, "p")

  local path = build_path(port)

  local content = vim.fn.json_encode({
    port          = port,
    workspacePath = vim.fn.getcwd(),
    authToken     = auth.get_token(),
    ideInfo       = {
      name        = ide_info.name,
      displayName = ide_info.display_name,
    },
  })

  -- Write via Neovim's file I/O
  local ok = pcall(function()
    local fh = io.open(path, "w")
    if not fh then
      error("Cannot open file for writing: " .. path)
    end
    fh:write(content)
    fh:close()
  end)

  if not ok then
    return false, "Failed to write discovery file: " .. path
  end

  discovery_file_path = path
  log.info("Discovery file created:", path)
  return true, nil
end

--- Delete the discovery file.
-- Safe to call even if the file does not exist.
function M.delete()
  if not discovery_file_path then
    return
  end

  local path = discovery_file_path
  discovery_file_path = nil

  local ok = os.remove(path)
  if ok then
    log.info("Discovery file deleted:", path)
  else
    log.warn("Could not delete discovery file (already gone?):", path)
  end
end

--- Return the currently active discovery file path (or nil).
-- @return string|nil
function M.get_path()
  return discovery_file_path
end

return M
