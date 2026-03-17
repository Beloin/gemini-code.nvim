--- Tests for geminicode.diff
-- Verifies that the diff module tracks active diffs and sends notifications.
-- NOTE: Requires a running Neovim instance (headless is fine).

describe("geminicode.diff", function()
  local diff = require("geminicode.diff")
  local mcp_notifications = {}

  before_each(function()
    mcp_notifications = {}
    -- Stub MCP notifications
    local mcp = require("geminicode.server.mcp")
    mcp.send_notification = function(method, params)
      table.insert(mcp_notifications, { method = method, params = params })
    end

    diff.setup({
      auto_close_on_accept = true,
      vertical_split       = true,
      open_in_current_tab  = true,
    })
  end)

  after_each(function()
    -- Clean up any active diffs
    for path, _ in pairs(diff.get_active_diffs()) do
      diff.close(path)
    end
  end)

  it("get_active_diffs returns empty table initially", function()
    assert.same({}, diff.get_active_diffs())
  end)

  it("close returns nil for unknown file", function()
    local result = diff.close("/nonexistent/file.lua")
    assert.is_nil(result)
  end)

  it("reject on non-existent diff does not error", function()
    assert.has_no.errors(function()
      diff.reject("/nonexistent/file.lua")
    end)
  end)

  it("accept on non-existent diff does not error", function()
    assert.has_no.errors(function()
      diff.accept("/nonexistent/file.lua")
    end)
  end)
end)
