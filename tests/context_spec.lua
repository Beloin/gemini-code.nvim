--- Tests for geminicode.context
-- Verifies context state tracking and debounce behaviour.
-- NOTE: These tests require a running Neovim instance (headless is fine).

describe("geminicode.context", function()
  local context = require("geminicode.context")
  local mcp_notifications = {}

  -- Stub out mcp.send_notification so we can capture calls
  before_each(function()
    mcp_notifications = {}
    local mcp = require("geminicode.server.mcp")
    mcp.send_notification = function(method, params)
      table.insert(mcp_notifications, { method = method, params = params })
    end
  end)

  after_each(function()
    context.stop()
  end)

  it("starts without errors", function()
    assert.has_no.errors(function()
      context.start({ debounce_ms = 1, max_files = 10, max_selection_bytes = 100 })
    end)
  end)

  it("add_file adds a file to the state", function()
    context.start({ debounce_ms = 1, max_files = 10, max_selection_bytes = 100 })
    context.add_file("/tmp/test_file.lua")

    local state = context.get_state()
    assert.is_not_nil(state["/tmp/test_file.lua"])
    assert.equals("/tmp/test_file.lua", state["/tmp/test_file.lua"].path)
  end)

  it("add_file ignores empty paths", function()
    context.start({ debounce_ms = 1, max_files = 10, max_selection_bytes = 100 })
    context.add_file("")
    context.add_file(nil)
    local state = context.get_state()
    assert.equals(0, vim.tbl_count(state))
  end)

  it("stop clears internal state", function()
    context.start({ debounce_ms = 1, max_files = 10, max_selection_bytes = 100 })
    context.add_file("/tmp/test_file.lua")
    context.stop()
    local state = context.get_state()
    assert.equals(0, vim.tbl_count(state))
  end)
end)
