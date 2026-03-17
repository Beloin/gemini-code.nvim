--- Tool registry init for gemini-code.nvim
-- Registers all MCP tools with the MCP dispatcher.
-- @module geminicode.tools

local M = {}

--- Register all built-in tools with the MCP module.
-- Must be called after the MCP module is loaded.
function M.setup()
  local open_diff  = require("geminicode.tools.open_diff")
  local close_diff = require("geminicode.tools.close_diff")

  open_diff.register()
  close_diff.register()
end

return M
