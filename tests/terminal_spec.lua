--- Integration tests for geminicode.terminal
-- Covers command generation, toggle state machine, auto-edit mode,
-- and the public init API wrappers (toggle_terminal / toggle_terminal_auto_edit).
--
-- Run with:
--   nvim --headless -u NONE \
--     -c "set rtp+=path/to/plenary.nvim" \
--     -c "lua require('plenary.busted').run('tests/')" \
--     -c "qa!"

describe("geminicode.terminal", function()
  local terminal

  -- vim.cmd calls captured during each test
  local cmd_calls = {}

  -- Stable fake buf/win IDs returned by mocked API
  local FAKE_BUF = 42
  local FAKE_WIN = 99

  -- Set of buffers that are "valid"
  local valid_bufs = {}
  -- List of windows returned by nvim_list_wins
  local listed_wins = {}
  -- Map win → buf for nvim_win_get_buf
  local win_buf_map = {}
  -- Tracks whether nvim_win_close was called
  local win_close_calls = {}
  -- Tracks whether nvim_buf_delete was called
  local buf_delete_calls = {}
  -- "current" window (for nvim_get_current_win)
  local current_win = FAKE_WIN

  -- ── Saved originals (restored in after_each) ───────────────────────────────
  local orig = {}

  local function save_orig(tbl, key)
    orig[key] = tbl[key]
  end

  local function restore_orig(tbl, key)
    tbl[key] = orig[key]
  end

  -- ── Module reset helpers ───────────────────────────────────────────────────
  local function reset_modules()
    package.loaded["geminicode.terminal"]    = nil
    package.loaded["geminicode.server.tcp"]  = nil
    package.loaded["geminicode.log"]         = nil
    package.loaded["geminicode"]             = nil
  end

  local function stub_deps()
    -- Stub tcp: always return a fixed port so env var is predictable
    package.loaded["geminicode.server.tcp"] = {
      get_port = function() return 12345 end,
    }
    -- Stub log to silence output
    package.loaded["geminicode.log"] = {
      warn  = function() end,
      info  = function() end,
      debug = function() end,
      error = function() end,
    }
  end

  -- ── Setup / Teardown ───────────────────────────────────────────────────────
  before_each(function()
    -- Reset captured state
    cmd_calls       = {}
    valid_bufs      = { [FAKE_BUF] = true }
    listed_wins     = {}
    win_buf_map     = {}
    win_close_calls = {}
    buf_delete_calls = {}
    current_win     = FAKE_WIN

    -- Save & replace vim.cmd
    save_orig(_G, "vim")  -- we only patch sub-fields, keep the save for safety
    orig.vim_cmd = vim.cmd
    vim.cmd = function(s) table.insert(cmd_calls, s) end

    -- Save & patch vim.api.*
    local api = vim.api
    save_orig(api, "nvim_get_current_buf")
    save_orig(api, "nvim_get_current_win")
    save_orig(api, "nvim_win_set_width")
    save_orig(api, "nvim_buf_set_name")
    save_orig(api, "nvim_create_autocmd")
    save_orig(api, "nvim_buf_is_valid")
    save_orig(api, "nvim_list_wins")
    save_orig(api, "nvim_win_get_buf")
    save_orig(api, "nvim_win_close")
    save_orig(api, "nvim_win_is_valid")
    save_orig(api, "nvim_buf_delete")
    save_orig(api, "nvim_set_current_win")
    save_orig(api, "nvim_set_current_buf")

    api.nvim_get_current_buf  = function()     return FAKE_BUF end
    api.nvim_get_current_win  = function()     return current_win end
    api.nvim_win_set_width    = function()     end
    api.nvim_buf_set_name     = function()     end
    api.nvim_create_autocmd   = function()     end
    api.nvim_buf_is_valid     = function(b)    return valid_bufs[b] == true end
    api.nvim_win_is_valid     = function()     return true end
    api.nvim_list_wins        = function()     return listed_wins end
    api.nvim_win_get_buf      = function(w)    return win_buf_map[w] end
    api.nvim_win_close        = function(w, _) table.insert(win_close_calls, w) end
    api.nvim_buf_delete       = function(b, _) table.insert(buf_delete_calls, b) end
    api.nvim_set_current_win  = function()     end
    api.nvim_set_current_buf  = function()     end

    -- Reset modules and inject stubs
    reset_modules()
    stub_deps()

    -- Load terminal, force native provider so tests don't need snacks
    terminal = require("geminicode.terminal")
    terminal.setup({ terminal = { provider = "native" } })
  end)

  after_each(function()
    -- Restore vim.cmd
    vim.cmd = orig.vim_cmd

    -- Restore vim.api.*
    local api = vim.api
    api.nvim_get_current_buf  = orig.nvim_get_current_buf
    api.nvim_get_current_win  = orig.nvim_get_current_win
    api.nvim_win_set_width    = orig.nvim_win_set_width
    api.nvim_buf_set_name     = orig.nvim_buf_set_name
    api.nvim_create_autocmd   = orig.nvim_create_autocmd
    api.nvim_buf_is_valid     = orig.nvim_buf_is_valid
    api.nvim_list_wins        = orig.nvim_list_wins
    api.nvim_win_get_buf      = orig.nvim_win_get_buf
    api.nvim_win_close        = orig.nvim_win_close
    api.nvim_win_is_valid     = orig.nvim_win_is_valid
    api.nvim_buf_delete       = orig.nvim_buf_delete
    api.nvim_set_current_win  = orig.nvim_set_current_win
    api.nvim_set_current_buf  = orig.nvim_set_current_buf

    reset_modules()
  end)

  -- ── Helpers ────────────────────────────────────────────────────────────────
  --- Return the "terminal <cmd>" call, or nil
  local function terminal_cmd_call()
    for _, c in ipairs(cmd_calls) do
      if c:find("^terminal ") then return c end
    end
    return nil
  end

  -- ── Tests: command generation ──────────────────────────────────────────────
  describe("command generation", function()
    it("includes the port env var", function()
      terminal.toggle()
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("GEMINI_CLI_IDE_SERVER_PORT=12345", 1, true))
    end)

    it("uses 'gemini' as default executable", function()
      terminal.toggle()
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("%f[%w]gemini%f[%W]"))  -- word boundary
    end)

    it("uses custom terminal_cmd when configured", function()
      reset_modules()
      stub_deps()
      terminal = require("geminicode.terminal")
      terminal.setup({ terminal_cmd = "my-gemini", terminal = { provider = "native" } })

      terminal.toggle()
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("my-gemini", 1, true))
    end)

    it("always includes --ide flag for IDE companion mode", function()
      terminal.toggle()
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("--ide", 1, true))
    end)

    it("includes --ide even when extra args are passed", function()
      terminal.toggle("--approval-mode=auto_edit")
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("--ide", 1, true))
    end)

    it("default toggle does NOT append flags other than --ide", function()
      terminal.toggle()
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_falsy(cmd:find("--approval-mode", 1, true))
    end)
  end)

  -- ── Tests: auto-edit mode ──────────────────────────────────────────────────
  describe("--approval-mode=auto_edit", function()
    it("appends the flag when toggle() receives it", function()
      terminal.toggle("--approval-mode=auto_edit")
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("--approval-mode=auto_edit", 1, true))
    end)

    it("still includes the port env var with auto_edit", function()
      terminal.toggle("--approval-mode=auto_edit")
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      assert.is_truthy(cmd:find("GEMINI_CLI_IDE_SERVER_PORT=12345", 1, true))
    end)

    it("flag appears AFTER the executable, not before", function()
      terminal.toggle("--approval-mode=auto_edit")
      local cmd = terminal_cmd_call()
      assert.is_not_nil(cmd)
      -- "gemini --approval-mode=auto_edit"
      local exec_pos = cmd:find("gemini", 1, true)
      local flag_pos = cmd:find("--approval-mode", 1, true)
      assert.is_not_nil(exec_pos)
      assert.is_not_nil(flag_pos)
      assert.is_true(flag_pos > exec_pos)
    end)

    it("default toggle() produces a different command than auto_edit toggle", function()
      terminal.toggle()
      local default_cmd = terminal_cmd_call()

      -- Reset terminal state for second open
      reset_modules()
      stub_deps()
      terminal = require("geminicode.terminal")
      terminal.setup({ terminal = { provider = "native" } })
      cmd_calls = {}

      terminal.toggle("--approval-mode=auto_edit")
      local auto_cmd = terminal_cmd_call()

      assert.is_not_nil(default_cmd)
      assert.is_not_nil(auto_cmd)
      assert.not_equals(default_cmd, auto_cmd)
    end)
  end)

  -- ── Tests: toggle state machine ────────────────────────────────────────────
  describe("toggle state machine", function()
    it("is_open() is false before any toggle", function()
      assert.is_false(terminal.is_open())
    end)

    it("is_open() is true after first toggle", function()
      terminal.toggle()
      assert.is_true(terminal.is_open())
    end)

    it("is_open() is true after auto_edit toggle", function()
      terminal.toggle("--approval-mode=auto_edit")
      assert.is_true(terminal.is_open())
    end)

    it("hides the window when toggled while terminal is focused", function()
      terminal.toggle()
      -- Simulate: terminal win is visible and currently focused
      listed_wins  = { FAKE_WIN }
      win_buf_map  = { [FAKE_WIN] = FAKE_BUF }
      current_win  = FAKE_WIN
      vim.api.nvim_list_wins   = function() return listed_wins end
      vim.api.nvim_win_get_buf = function(w) return win_buf_map[w] end
      vim.api.nvim_get_current_win = function() return current_win end

      cmd_calls = {}
      terminal.toggle()

      assert.equals(1, #win_close_calls)
    end)

    it("focuses the window when toggled while visible but not focused", function()
      terminal.toggle()
      local other_win = FAKE_WIN + 1
      listed_wins  = { FAKE_WIN }
      win_buf_map  = { [FAKE_WIN] = FAKE_BUF }
      current_win  = other_win  -- different window is active
      vim.api.nvim_list_wins   = function() return listed_wins end
      vim.api.nvim_win_get_buf = function(w) return win_buf_map[w] end
      vim.api.nvim_get_current_win = function() return current_win end

      local set_win_calls = {}
      vim.api.nvim_set_current_win = function(w) table.insert(set_win_calls, w) end

      cmd_calls = {}
      terminal.toggle()

      -- Should focus (set current win) rather than close
      assert.equals(0, #win_close_calls)
      assert.equals(1, #set_win_calls)
      assert.equals(FAKE_WIN, set_win_calls[1])
    end)

    it("close() deletes the buffer and resets is_open()", function()
      terminal.toggle()
      assert.is_true(terminal.is_open())

      terminal.close()
      assert.is_false(terminal.is_open())
      assert.equals(1, #buf_delete_calls)
      assert.equals(FAKE_BUF, buf_delete_calls[1])
    end)

    it("second toggle after close() reopens a fresh terminal", function()
      terminal.toggle()
      terminal.close()
      assert.is_false(terminal.is_open())

      cmd_calls = {}
      terminal.toggle()
      assert.is_true(terminal.is_open())
      assert.is_not_nil(terminal_cmd_call())
    end)
  end)

  -- ── Tests: init API delegation ─────────────────────────────────────────────
  describe("init API", function()
    local function load_init_with_mock_terminal(mock_term)
      reset_modules()
      stub_deps()
      package.loaded["geminicode.terminal"] = mock_term
      -- Also stub modules init.lua may require during setup (we don't call setup here)
      package.loaded["geminicode.config"]       = { setup = function() end, options = {} }
      package.loaded["geminicode.log"]          = { warn = function() end, info = function() end,
                                                    set_level = function() end, debug = function() end }
      package.loaded["geminicode.server"]       = { start = function() end, stop = function() end }
      package.loaded["geminicode.discovery"]    = { create = function() end, delete = function() end }
      package.loaded["geminicode.context"]      = { start = function() end, stop = function() end }
      return require("geminicode")
    end

    it("toggle_terminal() calls terminal.toggle() with no args", function()
      local captured = "SENTINEL"
      local mock_term = { toggle = function(args) captured = args end, setup = function() end }

      local api = load_init_with_mock_terminal(mock_term)
      api.toggle_terminal()
      assert.is_nil(captured)
    end)

    it("toggle_terminal_auto_edit() calls terminal.toggle('--approval-mode=auto_edit')", function()
      local captured = "SENTINEL"
      local mock_term = { toggle = function(args) captured = args end, setup = function() end }

      local api = load_init_with_mock_terminal(mock_term)
      api.toggle_terminal_auto_edit()
      assert.equals("--approval-mode=auto_edit", captured)
    end)
  end)
end)
