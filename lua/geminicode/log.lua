--- Logger module for gemini-code.nvim
-- Provides leveled logging with optional file output.
-- @module geminicode.log

local M = {}

--- Log level definitions (ordered by verbosity)
local LEVELS = {
  trace = 1,
  debug = 2,
  info  = 3,
  warn  = 4,
  error = 5,
}

--- Current configured minimum log level
local current_level = LEVELS.info

--- Set the minimum log level.
-- @param level string One of: "trace", "debug", "info", "warn", "error"
function M.set_level(level)
  local l = LEVELS[level]
  if not l then
    vim.notify("[geminicode] Invalid log level: " .. tostring(level), vim.log.levels.WARN)
    return
  end
  current_level = l
end

--- Internal log function.
-- @param level string
-- @param msg string
-- @param ... any Additional values concatenated to the message
local function log(level, msg, ...)
  if LEVELS[level] < current_level then
    return
  end

  local parts = { msg }
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "table" then
      parts[#parts + 1] = vim.inspect(v)
    else
      parts[#parts + 1] = tostring(v)
    end
  end

  local full_msg = "[geminicode][" .. level:upper() .. "] " .. table.concat(parts, " ")

  local nvim_level = vim.log.levels.INFO
  if level == "warn" then
    nvim_level = vim.log.levels.WARN
  elseif level == "error" then
    nvim_level = vim.log.levels.ERROR
  elseif level == "debug" or level == "trace" then
    nvim_level = vim.log.levels.DEBUG
  end

  vim.notify(full_msg, nvim_level)
end

--- Log at TRACE level.
function M.trace(msg, ...) log("trace", msg, ...) end

--- Log at DEBUG level.
function M.debug(msg, ...) log("debug", msg, ...) end

--- Log at INFO level.
function M.info(msg, ...) log("info", msg, ...) end

--- Log at WARN level.
function M.warn(msg, ...) log("warn", msg, ...) end

--- Log at ERROR level.
function M.error(msg, ...) log("error", msg, ...) end

return M
