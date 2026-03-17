--- openDiff MCP tool for gemini-code.nvim
-- Called by the Gemini CLI to propose file changes.
-- Opens a native Neovim diff view and returns immediately.
-- The accept/reject result is sent asynchronously via notifications.
-- @module geminicode.tools.open_diff

local mcp  = require("geminicode.server.mcp")
local diff = require("geminicode.diff")
local log  = require("geminicode.log")

local M = {}

--- Register the openDiff tool with the MCP dispatcher.
function M.register()
  mcp.register_tool(
    "openDiff",
    {
      description = "Open a diff view in Neovim showing the proposed file changes from Gemini.",
      inputSchema = {
        type       = "object",
        required   = { "filePath", "newContent" },
        properties = {
          filePath = {
            type        = "string",
            description = "Absolute path to the file being modified",
          },
          newContent = {
            type        = "string",
            description = "The full proposed new content for the file",
          },
        },
        additionalProperties = false,
      },
    },
    function(args)
      local file_path  = args.filePath
      local new_content = args.newContent

      if type(file_path) ~= "string" or file_path == "" then
        error("openDiff: filePath is required and must be a non-empty string")
      end
      if type(new_content) ~= "string" then
        error("openDiff: newContent is required and must be a string")
      end

      log.info("openDiff called for:", file_path)

      -- Open the diff view (non-blocking; notifications sent asynchronously)
      vim.schedule(function()
        local ok, err = diff.open(file_path, new_content)
        if not ok then
          log.error("openDiff failed:", err)
        end
      end)

      -- Return immediately with an empty content array (per spec)
      return { content = {} }
    end
  )
end

return M
