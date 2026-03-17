--- Tests for geminicode.diff
-- Verifies that the diff module tracks active diffs, sends notifications,
-- opens floating windows, and leaves the user's existing window layout
-- completely intact after accept or reject.
--
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

  -- ── Baseline state ────────────────────────────────────────────────────────

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

  -- ── Floating windows + window-layout isolation ─────────────────────────────
  --
  -- These tests verify that the diff view uses floating windows (so the user's
  -- splits are never touched) and that both floats are closed on accept/reject.

  describe("window isolation (floating diff)", function()
    local tmp_file

    before_each(function()
      -- Create a real file so vim.cmd("write") in accept_diff succeeds
      tmp_file = vim.fn.tempname() .. ".lua"
      local fh = assert(io.open(tmp_file, "w"))
      fh:write("-- original\n")
      fh:close()
    end)

    after_each(function()
      -- Close any stray diff
      for path, _ in pairs(diff.get_active_diffs()) do
        diff.close(path)
      end
      os.remove(tmp_file)
    end)

    --- Flush vim.schedule callbacks by yielding to the event loop.
    local function flush(ms)
      vim.wait(ms or 300, function() return false end)
    end

    it("open() adds two floating windows on top of existing layout", function()
      local before = vim.api.nvim_list_wins()

      diff.open(tmp_file, "-- proposed\n")
      flush()

      local after = vim.api.nvim_list_wins()
      -- Exactly two new windows (orig float + proposed float)
      assert.equals(#before + 2, #after)
    end)

    it("the two new windows are floating", function()
      diff.open(tmp_file, "-- proposed\n")
      flush()

      local active = diff.get_active_diffs()
      local d = active[tmp_file]
      assert.is_not_nil(d, "diff state must exist after open()")
      assert.is_not_nil(d.orig_winid,     "orig_winid must be set")
      assert.is_not_nil(d.proposed_winid, "proposed_winid must be set")

      -- Both windows must report relative = "editor" (i.e. floating)
      local orig_cfg     = vim.api.nvim_win_get_config(d.orig_winid)
      local proposed_cfg = vim.api.nvim_win_get_config(d.proposed_winid)
      assert.equals("editor", orig_cfg.relative)
      assert.equals("editor", proposed_cfg.relative)
    end)

    it("accept: closes both diff floats, user windows survive", function()
      -- Simulate user having their own window open
      vim.cmd("new")
      local user_win  = vim.api.nvim_get_current_win()
      local user_wins = vim.api.nvim_list_wins()

      diff.open(tmp_file, "-- proposed\n")
      flush()

      -- Grab the diff window IDs before accepting
      local d            = diff.get_active_diffs()[tmp_file]
      local orig_win     = d.orig_winid
      local proposed_win = d.proposed_winid

      diff.accept(tmp_file)
      flush(200)

      -- Both diff floats must be gone
      assert.is_false(vim.api.nvim_win_is_valid(orig_win),     "orig float must be closed after accept")
      assert.is_false(vim.api.nvim_win_is_valid(proposed_win), "proposed float must be closed after accept")

      -- User window must still exist and window count must be back to pre-diff
      assert.is_true(vim.api.nvim_win_is_valid(user_win), "user window must survive accept")
      assert.equals(#user_wins, #vim.api.nvim_list_wins())

      pcall(vim.api.nvim_win_close, user_win, true)
    end)

    it("reject: closes both diff floats, user windows survive", function()
      vim.cmd("new")
      local user_win  = vim.api.nvim_get_current_win()
      local user_wins = vim.api.nvim_list_wins()

      diff.open(tmp_file, "-- proposed\n")
      flush()

      local d            = diff.get_active_diffs()[tmp_file]
      local orig_win     = d.orig_winid
      local proposed_win = d.proposed_winid

      diff.reject(tmp_file)
      flush(200)

      assert.is_false(vim.api.nvim_win_is_valid(orig_win),     "orig float must be closed after reject")
      assert.is_false(vim.api.nvim_win_is_valid(proposed_win), "proposed float must be closed after reject")

      assert.is_true(vim.api.nvim_win_is_valid(user_win), "user window must survive reject")
      assert.equals(#user_wins, #vim.api.nvim_list_wins())

      pcall(vim.api.nvim_win_close, user_win, true)
    end)

    it("accept: multiple user windows all survive", function()
      -- Open three user windows (typical multi-split layout)
      vim.cmd("new")
      vim.cmd("vsplit")
      vim.cmd("split")
      local user_wins = vim.api.nvim_list_wins()
      assert.is_true(#user_wins >= 3)

      diff.open(tmp_file, "-- proposed\n")
      flush()

      diff.accept(tmp_file)
      flush(200)

      -- Every pre-diff window must still be valid
      for _, w in ipairs(user_wins) do
        assert.is_true(vim.api.nvim_win_is_valid(w),
          "user window " .. w .. " must survive accept")
      end
      assert.equals(#user_wins, #vim.api.nvim_list_wins())

      -- Teardown
      for _, w in ipairs(user_wins) do
        pcall(vim.api.nvim_win_close, w, true)
      end
    end)

    it("reject: multiple user windows all survive", function()
      vim.cmd("new")
      vim.cmd("vsplit")
      local user_wins = vim.api.nvim_list_wins()

      diff.open(tmp_file, "-- proposed\n")
      flush()

      diff.reject(tmp_file)
      flush(200)

      for _, w in ipairs(user_wins) do
        assert.is_true(vim.api.nvim_win_is_valid(w),
          "user window " .. w .. " must survive reject")
      end
      assert.equals(#user_wins, #vim.api.nvim_list_wins())

      for _, w in ipairs(user_wins) do
        pcall(vim.api.nvim_win_close, w, true)
      end
    end)

    it("accept sends ide/diffAccepted notification with content", function()
      diff.open(tmp_file, "-- accepted content\n")
      flush()

      diff.accept(tmp_file)
      flush(200)

      assert.equals(1, #mcp_notifications)
      assert.equals("ide/diffAccepted", mcp_notifications[1].method)
      assert.is_truthy(mcp_notifications[1].params.content:find("accepted content", 1, true))
    end)

    it("reject sends ide/diffRejected notification", function()
      diff.open(tmp_file, "-- proposed\n")
      flush()

      diff.reject(tmp_file)
      flush(200)

      assert.equals(1, #mcp_notifications)
      assert.equals("ide/diffRejected", mcp_notifications[1].method)
      assert.equals(tmp_file, mcp_notifications[1].params.filePath)
    end)

    it("active_diffs is empty after accept", function()
      diff.open(tmp_file, "-- proposed\n")
      flush()

      diff.accept(tmp_file)
      flush(200)

      assert.same({}, diff.get_active_diffs())
    end)

    it("active_diffs is empty after reject", function()
      diff.open(tmp_file, "-- proposed\n")
      flush()

      diff.reject(tmp_file)
      flush(200)

      assert.same({}, diff.get_active_diffs())
    end)
  end)
end)
