--- closeDiff MCP tool for gemini-code.nvim
-- Called by the Gemini CLI to programmatically close a diff view.
-- Returns the final file content in the response.
-- @module geminicode.tools.close_diff

local mcp  = require("geminicode.server.mcp")
local diff = require("geminicode.diff")
local log  = require("geminicode.log")

local M = {}

--- Register the closeDiff tool with the MCP dispatcher.
function M.register()
  mcp.register_tool(
    "closeDiff",
    {
      description = "Programmatically close the diff view for a file.",
      inputSchema = {
        type       = "object",
        required   = { "filePath" },
        properties = {
          filePath = {
            type        = "string",
            description = "Absolute path to the file whose diff should be closed",
          },
        },
        additionalProperties = false,
      },
    },
    function(args)
      local file_path = args.filePath

      if type(file_path) ~= "string" or file_path == "" then
        error("closeDiff: filePath is required and must be a non-empty string")
      end

      log.info("closeDiff called for:", file_path)

      local final_content = diff.close(file_path)

      if final_content then
        return {
          content = {
            { type = "text", text = final_content },
          },
        }
      else
        -- No active diff for this file — return empty content
        return { content = {} }
      end
    end
  )
end

return M
