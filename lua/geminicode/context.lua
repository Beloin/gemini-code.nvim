--- Context tracking module for gemini-code.nvim
-- Monitors open buffers, cursor positions, and text selections.
-- Sends ide/contextUpdate MCP notifications to the Gemini CLI (debounced).
-- @module geminicode.context

local log = require("geminicode.log")
local mcp = require("geminicode.server.mcp")

local M = {}

--- @type table  file_path → file entry
local open_files = {}

--- @type uv_timer_t|nil  Debounce timer handle
local debounce_timer = nil

--- @type integer  Debounce interval in milliseconds
local debounce_ms = 50

--- @type integer  Maximum number of files to include in context
local max_files = 10

--- @type integer  Maximum bytes for selectedText
local max_selection_bytes = 16384

--- @type integer[]  Autocmd group ID
local augroup_id = nil

--- Return the absolute path of a buffer (or nil for unnamed/scratch buffers).
-- @param bufnr integer
-- @return string|nil
local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return nil
  end
  -- Exclude unnamed and non-file buffers
  local bt = vim.api.nvim_buf_get_option(bufnr, "buftype")
  if bt ~= "" then
    return nil
  end
  return name
end

--- Return current Unix timestamp in milliseconds.
-- @return integer
local function now_ms()
  return math.floor(vim.loop.hrtime() / 1e6)
end

--- Cancel and restart the debounce timer, then call `fn` after the interval.
-- @param fn function
local function debounce(fn)
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
  end
  debounce_timer = vim.loop.new_timer()
  debounce_timer:start(debounce_ms, 0, function()
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
    vim.schedule(fn)
  end)
end

--- Send the ide/contextUpdate notification to the CLI.
local function send_context_update()
  -- Collect and sort by timestamp descending
  local files = {}
  for _, entry in pairs(open_files) do
    table.insert(files, entry)
  end
  table.sort(files, function(a, b)
    return (a.timestamp or 0) > (b.timestamp or 0)
  end)

  -- Truncate to max_files
  if #files > max_files then
    for i = max_files + 1, #files do
      files[i] = nil
    end
  end

  -- Build the File objects
  local file_list = {}
  for _, f in ipairs(files) do
    local file_obj = {
      path      = f.path,
      timestamp = f.timestamp,
    }
    if f.is_active then
      file_obj.isActive = true
    end
    if f.cursor then
      file_obj.cursor = { line = f.cursor.line, character = f.cursor.character }
    end
    if f.selected_text and f.selected_text ~= "" then
      local text = f.selected_text
      if #text > max_selection_bytes then
        text = text:sub(1, max_selection_bytes)
      end
      file_obj.selectedText = text
    end
    table.insert(file_list, file_obj)
  end

  mcp.send_notification("ide/contextUpdate", {
    workspaceState = {
      openFiles = file_list,
      isTrusted = true,
    },
  })
end

--- Schedule a debounced context update.
local function schedule_update()
  debounce(send_context_update)
end

--- Mark a buffer as active and update its timestamp.
-- @param bufnr integer
local function activate_buffer(bufnr)
  local path = buf_path(bufnr)
  if not path then return end

  -- Deactivate all others
  for _, entry in pairs(open_files) do
    entry.is_active = false
  end

  if not open_files[path] then
    open_files[path] = { path = path }
  end
  open_files[path].is_active = true
  open_files[path].timestamp = now_ms()
end

--- Update cursor position for the given buffer.
-- @param bufnr integer
local function update_cursor(bufnr)
  local path = buf_path(bufnr)
  if not path then return end

  local pos = vim.api.nvim_win_get_cursor(0)  -- {row, col} (1-based row, 0-based col)
  if not open_files[path] then
    open_files[path] = { path = path, timestamp = now_ms() }
  end
  open_files[path].cursor = {
    line      = pos[1],          -- already 1-based
    character = pos[2] + 1,      -- convert to 1-based
  }
end

--- Capture the current visual selection for the given buffer.
-- @param bufnr integer
local function capture_selection(bufnr)
  local path = buf_path(bufnr)
  if not path then return end

  if not open_files[path] then
    open_files[path] = { path = path, timestamp = now_ms() }
  end

  -- Get visual marks
  local ok, lines = pcall(function()
    local start_pos = vim.fn.getpos("'<")
    local end_pos   = vim.fn.getpos("'>")
    return vim.api.nvim_buf_get_lines(
      bufnr,
      start_pos[2] - 1,  -- 0-based start
      end_pos[2],         -- exclusive end (1-based end → exclusive 0-based)
      false
    )
  end)

  if ok and lines and #lines > 0 then
    open_files[path].selected_text = table.concat(lines, "\n")
  else
    open_files[path].selected_text = nil
  end
end

--- Clear the selection for the given buffer.
-- @param bufnr integer
local function clear_selection(bufnr)
  local path = buf_path(bufnr)
  if not path or not open_files[path] then return end
  open_files[path].selected_text = nil
end

--- Remove a buffer from the tracked list when it's closed.
-- @param bufnr integer
local function remove_buffer(bufnr)
  local path = buf_path(bufnr)
  if path then
    open_files[path] = nil
  end
end

--- Start context tracking (register autocmds).
-- @param opts table  { debounce_ms, max_files, max_selection_bytes }
function M.start(opts)
  opts = opts or {}
  debounce_ms          = opts.debounce_ms          or 50
  max_files            = opts.max_files            or 10
  max_selection_bytes  = opts.max_selection_bytes  or 16384

  augroup_id = vim.api.nvim_create_augroup("GeminiCodeContext", { clear = true })

  -- Buffer focus / open
  vim.api.nvim_create_autocmd({ "BufEnter", "BufAdd" }, {
    group   = augroup_id,
    callback = function(ev)
      activate_buffer(ev.buf)
      schedule_update()
    end,
  })

  -- Buffer close
  vim.api.nvim_create_autocmd("BufDelete", {
    group   = augroup_id,
    callback = function(ev)
      remove_buffer(ev.buf)
      schedule_update()
    end,
  })

  -- Cursor movement (normal + insert)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group   = augroup_id,
    callback = function(ev)
      update_cursor(ev.buf)
      schedule_update()
    end,
  })

  -- Mode changes — capture selection when leaving visual mode
  vim.api.nvim_create_autocmd("ModeChanged", {
    group   = augroup_id,
    pattern = "[vVsS\x16\x13]:.*",   -- leaving any visual/select mode (old:new format)
    callback = function(ev)
      -- Capture the selection just before leaving visual mode
      local prev_mode = ev.match:match("^([^:]*)")
      if prev_mode and (
          prev_mode:find("[vV]") or
          prev_mode:find("\x16") or   -- CTRL-V block visual
          prev_mode:find("[sS]")       -- select mode
        ) then
        capture_selection(ev.buf)
      else
        clear_selection(ev.buf)
      end
      schedule_update()
    end,
  })

  log.info("Context tracking started")
end

--- Stop context tracking (remove autocmds and cancel timers).
function M.stop()
  if augroup_id then
    vim.api.nvim_del_augroup_by_id(augroup_id)
    augroup_id = nil
  end
  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
  end
  open_files = {}
  log.info("Context tracking stopped")
end

--- Manually add a file to the tracked context.
-- @param path string  Absolute path
function M.add_file(path)
  if not path or path == "" then return end
  if not open_files[path] then
    open_files[path] = { path = path, timestamp = now_ms() }
  end
  schedule_update()
end

--- Return a copy of the current open_files state (for testing/debugging).
-- @return table
function M.get_state()
  return vim.deepcopy(open_files)
end

return M
