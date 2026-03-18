--- Tests for geminicode.send_selection()
-- Verifies that the function sends @file#Lstart-end references to the terminal.
--
-- Run with:
--   nvim --headless -u NONE \
--     -c "set rtp+=path/to/plenary.nvim" \
--     -c "lua require('plenary.busted').run('tests/send_selection_spec.lua')" \
--     -c "qa!"

describe("geminicode.send_selection", function()
  local geminicode

  -- Captured calls to mock terminal
  local focus_calls
  local send_calls
  -- Captured log.warn messages
  local warn_calls

  -- Mock values
  local buf_name
  local getpos_results  -- map of mark → {0, line, col, 0}
  local fnamemodify_result

  -- ── Saved originals ──────────────────────────────────────────────────────
  local orig_buf_get_name
  local orig_getpos
  local orig_fnamemodify

  local function reset_modules()
    package.loaded["geminicode"]             = nil
    package.loaded["geminicode.terminal"]    = nil
    package.loaded["geminicode.log"]         = nil
    package.loaded["geminicode.config"]      = nil
    package.loaded["geminicode.server"]      = nil
    package.loaded["geminicode.discovery"]   = nil
    package.loaded["geminicode.context"]     = nil
    package.loaded["geminicode.diff"]        = nil
    package.loaded["geminicode.tools"]       = nil
    package.loaded["geminicode.server.tcp"]  = nil
  end

  before_each(function()
    focus_calls = {}
    send_calls  = {}
    warn_calls  = {}

    buf_name = "/project/src/main.lua"
    getpos_results = {
      ["'<"] = { 0, 5, 1, 0 },
      ["'>"] = { 0, 10, 1, 0 },
    }
    fnamemodify_result = "src/main.lua"

    -- Save originals
    orig_buf_get_name = vim.api.nvim_buf_get_name
    orig_getpos       = vim.fn.getpos
    orig_fnamemodify  = vim.fn.fnamemodify

    -- Mock vim.api.nvim_buf_get_name
    vim.api.nvim_buf_get_name = function(_) return buf_name end

    -- Mock vim.fn.getpos
    vim.fn.getpos = function(mark) return getpos_results[mark] or { 0, 0, 0, 0 } end

    -- Mock vim.fn.fnamemodify
    vim.fn.fnamemodify = function(_, _) return fnamemodify_result end

    -- Reset and stub dependencies
    reset_modules()

    package.loaded["geminicode.terminal"] = {
      focus = function() table.insert(focus_calls, true) end,
      send  = function(text) table.insert(send_calls, text) end,
      setup = function() end,
    }
    package.loaded["geminicode.log"] = {
      warn      = function(msg) table.insert(warn_calls, msg) end,
      info      = function() end,
      debug     = function() end,
      error     = function() end,
      set_level = function() end,
    }
    package.loaded["geminicode.config"]    = { setup = function() end, options = {} }
    package.loaded["geminicode.server"]    = { start = function() end, stop = function() end }
    package.loaded["geminicode.discovery"] = { create = function() end, delete = function() end }
    package.loaded["geminicode.context"]   = { start = function() end, stop = function() end }
    package.loaded["geminicode.diff"]      = { setup = function() end }
    package.loaded["geminicode.tools"]     = { setup = function() end }

    geminicode = require("geminicode")
  end)

  after_each(function()
    vim.api.nvim_buf_get_name = orig_buf_get_name
    vim.fn.getpos             = orig_getpos
    vim.fn.fnamemodify        = orig_fnamemodify
    reset_modules()
  end)

  it("sends @file#Lstart-end for a multi-line selection", function()
    geminicode.send_selection()

    assert.equals(1, #focus_calls)
    assert.equals(1, #send_calls)
    assert.equals("@src/main.lua#L5-10 ", send_calls[1])
  end)

  it("sends @file#L for a single-line selection", function()
    getpos_results["'<"] = { 0, 12, 1, 0 }
    getpos_results["'>"] = { 0, 12, 5, 0 }

    geminicode.send_selection()

    assert.equals(1, #send_calls)
    assert.equals("@src/main.lua#L12 ", send_calls[1])
  end)

  it("warns and returns when buffer has no file", function()
    buf_name = ""

    geminicode.send_selection()

    assert.equals(0, #send_calls)
    assert.equals(0, #focus_calls)
    assert.equals(1, #warn_calls)
    assert.is_truthy(warn_calls[1]:find("no file"))
  end)

  it("warns and returns when no selection marks", function()
    getpos_results["'<"] = { 0, 0, 0, 0 }
    getpos_results["'>"] = { 0, 0, 0, 0 }

    geminicode.send_selection()

    assert.equals(0, #send_calls)
    assert.equals(0, #focus_calls)
    assert.equals(1, #warn_calls)
    assert.is_truthy(warn_calls[1]:find("No selection"))
  end)

  it("focuses the terminal before sending", function()
    -- Track ordering: focus should happen before send
    local order = {}
    package.loaded["geminicode.terminal"].focus = function()
      table.insert(order, "focus")
    end
    package.loaded["geminicode.terminal"].send = function()
      table.insert(order, "send")
    end

    -- Reload to pick up updated stubs
    package.loaded["geminicode"] = nil
    geminicode = require("geminicode")

    geminicode.send_selection()

    assert.equals(2, #order)
    assert.equals("focus", order[1])
    assert.equals("send", order[2])
  end)

  it("sends with a trailing space and no newline", function()
    geminicode.send_selection()

    local sent = send_calls[1]
    assert.is_truthy(sent:match(" $"), "should end with a space")
    assert.is_falsy(sent:find("\n"), "should not contain a newline")
  end)

  it("uses relative path from fnamemodify", function()
    fnamemodify_result = "deeply/nested/file.lua"

    geminicode.send_selection()

    assert.equals("@deeply/nested/file.lua#L5-10 ", send_calls[1])
  end)
end)

describe("geminicode.send_buffer", function()
  local geminicode

  local focus_calls
  local send_calls
  local warn_calls

  local buf_name
  local fnamemodify_result

  local orig_buf_get_name
  local orig_fnamemodify

  local function reset_modules()
    package.loaded["geminicode"]             = nil
    package.loaded["geminicode.terminal"]    = nil
    package.loaded["geminicode.log"]         = nil
    package.loaded["geminicode.config"]      = nil
    package.loaded["geminicode.server"]      = nil
    package.loaded["geminicode.discovery"]   = nil
    package.loaded["geminicode.context"]     = nil
    package.loaded["geminicode.diff"]        = nil
    package.loaded["geminicode.tools"]       = nil
    package.loaded["geminicode.server.tcp"]  = nil
  end

  before_each(function()
    focus_calls = {}
    send_calls  = {}
    warn_calls  = {}

    buf_name = "/project/src/main.lua"
    fnamemodify_result = "src/main.lua"

    orig_buf_get_name = vim.api.nvim_buf_get_name
    orig_fnamemodify  = vim.fn.fnamemodify

    vim.api.nvim_buf_get_name = function(_) return buf_name end
    vim.fn.fnamemodify = function(_, _) return fnamemodify_result end

    reset_modules()

    package.loaded["geminicode.terminal"] = {
      focus = function() table.insert(focus_calls, true) end,
      send  = function(text) table.insert(send_calls, text) end,
      setup = function() end,
    }
    package.loaded["geminicode.log"] = {
      warn      = function(msg) table.insert(warn_calls, msg) end,
      info      = function() end,
      debug     = function() end,
      error     = function() end,
      set_level = function() end,
    }
    package.loaded["geminicode.config"]    = { setup = function() end, options = {} }
    package.loaded["geminicode.server"]    = { start = function() end, stop = function() end }
    package.loaded["geminicode.discovery"] = { create = function() end, delete = function() end }
    package.loaded["geminicode.context"]   = { start = function() end, stop = function() end }
    package.loaded["geminicode.diff"]      = { setup = function() end }
    package.loaded["geminicode.tools"]     = { setup = function() end }

    geminicode = require("geminicode")
  end)

  after_each(function()
    vim.api.nvim_buf_get_name = orig_buf_get_name
    vim.fn.fnamemodify        = orig_fnamemodify
    reset_modules()
  end)

  it("sends @file for the current buffer", function()
    geminicode.send_buffer()

    assert.equals(1, #focus_calls)
    assert.equals(1, #send_calls)
    assert.equals("@src/main.lua ", send_calls[1])
  end)

  it("warns and returns when buffer has no file", function()
    buf_name = ""

    geminicode.send_buffer()

    assert.equals(0, #send_calls)
    assert.equals(0, #focus_calls)
    assert.equals(1, #warn_calls)
    assert.is_truthy(warn_calls[1]:find("no file"))
  end)

  it("sends with trailing space and no newline", function()
    geminicode.send_buffer()

    local sent = send_calls[1]
    assert.is_truthy(sent:match(" $"), "should end with a space")
    assert.is_falsy(sent:find("\n"), "should not contain a newline")
  end)

  it("uses relative path from fnamemodify", function()
    fnamemodify_result = "lib/utils.lua"

    geminicode.send_buffer()

    assert.equals("@lib/utils.lua ", send_calls[1])
  end)
end)
