--- Diff view module for gemini-code.nvim
-- Opens a pair of floating windows (original | proposed) when the Gemini
-- CLI proposes file changes.  Floating windows overlay the editor without
-- disturbing the user's existing split layout — they are safely closed on
-- accept or reject.
-- @module geminicode.diff

local log = require("geminicode.log")
local mcp = require("geminicode.server.mcp")

local M = {}

--- Map of filePath → diff state:
--   { original_bufnr, proposed_bufnr, orig_winid, proposed_winid, accepted }
-- orig_winid / proposed_winid are nil until the vim.schedule callback fires.
local active_diffs = {}

--- Configuration (set from diff_opts in config)
local opts = {
  auto_close_on_accept = true,
  vertical_split       = true,   -- kept for compat; floats are always side-by-side
  open_in_current_tab  = true,
}

--- Configure diff behaviour.
-- @param diff_opts table  Values from config.diff_opts
function M.setup(diff_opts)
  opts = vim.tbl_deep_extend("force", opts, diff_opts or {})
end

--- Calculate geometry for two side-by-side floating windows.
-- @return table { row, col_left, col_right, w_left, w_right, height }
local function float_geometry()
  local total_w = vim.o.columns
  local total_h = vim.o.lines - vim.o.cmdheight
  local win_w   = math.floor(total_w * 0.7)
  local win_h   = math.max(10, math.floor(total_h * 0.7))
  local col_off = math.floor((total_w - win_w) / 2)
  local row_off = math.floor((total_h - win_h) / 2)
  local w_left  = math.floor((win_w - 3) / 2)
  local w_right = win_w - w_left - 3
  return {
    row     = row_off,
    col_l   = col_off,
    col_r   = col_off + w_left + 3,
    w_left  = w_left,
    w_right = w_right,
    height  = win_h,
  }
end

--- Open a diff view for the given file.
-- Called by the openDiff tool handler.
--
-- @param file_path   string  Absolute path to the file being changed
-- @param new_content string  The proposed new content from the CLI
-- @return boolean, string|nil  success, error
function M.open(file_path, new_content)
  if active_diffs[file_path] then
    M.close(file_path)
  end

  -- Load (or find) the original buffer
  local orig_bufnr = vim.fn.bufadd(file_path)
  vim.fn.bufload(orig_bufnr)

  -- Create a scratch buffer for the proposed content
  local proposed_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(proposed_bufnr, "buftype",   "acwrite") -- BufWriteCmd = accept
  vim.api.nvim_buf_set_option(proposed_bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_name(proposed_bufnr, file_path .. " [Gemini Proposed]")

  local lines = vim.split(new_content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  vim.api.nvim_buf_set_lines(proposed_bufnr, 0, -1, false, lines)

  -- Register diff state (window IDs filled in by the scheduled callback)
  active_diffs[file_path] = {
    original_bufnr = orig_bufnr,
    proposed_bufnr = proposed_bufnr,
    orig_winid     = nil,
    proposed_winid = nil,
    accepted       = false,
  }

  vim.schedule(function()
    local geo    = float_geometry()
    local border = "rounded"
    local fname  = vim.fn.fnamemodify(file_path, ":t")

    -- Left float: original file (not focused)
    local orig_win = vim.api.nvim_open_win(orig_bufnr, false, {
      relative  = "editor",
      row       = geo.row,
      col       = geo.col_l,
      width     = geo.w_left,
      height    = geo.height,
      style     = "minimal",
      border    = border,
      title     = string.format(" %s (original) ", fname),
      title_pos = "center",
    })

    -- Right float: proposed content (focused)
    local proposed_win = vim.api.nvim_open_win(proposed_bufnr, true, {
      relative  = "editor",
      row       = geo.row,
      col       = geo.col_r,
      width     = geo.w_right,
      height    = geo.height,
      style     = "minimal",
      border    = border,
      title     = " Gemini Proposed ",
      title_pos = "center",
    })

    -- Enable diff mode on both floats
    vim.api.nvim_win_call(orig_win,     function() vim.cmd("diffthis") end)
    vim.api.nvim_win_call(proposed_win, function() vim.cmd("diffthis") end)

    -- Persist window IDs so M.close() can reach them
    if active_diffs[file_path] then
      active_diffs[file_path].orig_winid     = orig_win
      active_diffs[file_path].proposed_winid = proposed_win
    end

    --- Close both diff floats; safe to call multiple times.
    local function close_diff_windows()
      if orig_win and vim.api.nvim_win_is_valid(orig_win) then
        vim.api.nvim_win_close(orig_win, true)
      end
      if proposed_win and vim.api.nvim_win_is_valid(proposed_win) then
        vim.api.nvim_win_close(proposed_win, true)
      end
    end

    local function accept_diff()
      if not active_diffs[file_path] then return end
      active_diffs[file_path].accepted = true

      local current_lines = vim.api.nvim_buf_get_lines(proposed_bufnr, 0, -1, false)
      local final_content = table.concat(current_lines, "\n")

      -- Write the accepted content to the original file
      local orig_lines = vim.split(final_content, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(orig_bufnr, 0, -1, false, orig_lines)
      vim.api.nvim_buf_call(orig_bufnr, function()
        vim.cmd("write")
      end)

      -- Notify the CLI
      mcp.send_notification("ide/diffAccepted", {
        filePath = file_path,
        content  = final_content,
      })

      log.info("Diff accepted:", file_path)
      active_diffs[file_path] = nil  -- clear before closing so BufWipeout is a no-op
      close_diff_windows()
    end

    local function reject_diff()
      if not active_diffs[file_path] then return end
      if not active_diffs[file_path].accepted then
        mcp.send_notification("ide/diffRejected", { filePath = file_path })
        log.info("Diff rejected:", file_path)
      end
      active_diffs[file_path] = nil  -- clear before closing so BufWipeout is a no-op
      close_diff_windows()
    end

    -- BufWriteCmd on the proposed buffer → accept
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer   = proposed_bufnr,
      once     = true,
      callback = function() accept_diff() end,
    })

    -- BufWipeout on the proposed buffer → reject (if not already accepted)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer   = proposed_bufnr,
      once     = true,
      callback = reject_diff,
    })

    -- Convenience keymaps in the proposed buffer
    local km_opts = { noremap = true, silent = true, buffer = proposed_bufnr }
    vim.keymap.set("n", "<leader>da", accept_diff, vim.tbl_extend("force", km_opts, {
      desc = "Accept Gemini diff",
    }))
    vim.keymap.set("n", "<leader>dr", function()
      vim.api.nvim_buf_delete(proposed_bufnr, { force = true })
    end, vim.tbl_extend("force", km_opts, { desc = "Reject Gemini diff" }))

    log.info("Diff floats opened for:", file_path)
  end)

  return true, nil
end

--- Close the diff view for a given file path.
-- Called by the closeDiff tool handler or from tests/cleanup.
-- @param file_path string
-- @return string|nil  Final content of the original buffer
function M.close(file_path)
  local diff = active_diffs[file_path]
  if not diff then
    return nil
  end

  active_diffs[file_path] = nil  -- clear first so BufWipeout callbacks no-op

  -- Close the floating windows we opened
  if diff.orig_winid and vim.api.nvim_win_is_valid(diff.orig_winid) then
    vim.api.nvim_win_close(diff.orig_winid, true)
  end
  if diff.proposed_winid and vim.api.nvim_win_is_valid(diff.proposed_winid) then
    vim.api.nvim_win_close(diff.proposed_winid, true)
  elseif diff.proposed_bufnr and vim.api.nvim_buf_is_valid(diff.proposed_bufnr) then
    -- proposed window already gone; wipe the buffer directly
    vim.api.nvim_buf_delete(diff.proposed_bufnr, { force = true })
  end

  -- Return current content of the original buffer
  local orig = diff.original_bufnr
  if orig and vim.api.nvim_buf_is_valid(orig) then
    local lines = vim.api.nvim_buf_get_lines(orig, 0, -1, false)
    return table.concat(lines, "\n")
  end

  return nil
end

--- Accept the currently active diff (called from user command).
-- @param file_path string|nil  Defaults to current buffer path
function M.accept(file_path)
  file_path = file_path or vim.api.nvim_buf_get_name(0)
  for _, diff in pairs(active_diffs) do
    if vim.api.nvim_buf_is_valid(diff.proposed_bufnr) then
      -- Trigger BufWriteCmd → accept_diff closure
      vim.api.nvim_buf_call(diff.proposed_bufnr, function()
        vim.cmd("write")
      end)
      return
    end
  end
  log.warn("No active diff to accept")
end

--- Reject the currently active diff (called from user command).
-- @param file_path string|nil  Defaults to current buffer path
function M.reject(file_path)
  file_path = file_path or vim.api.nvim_buf_get_name(0)
  for _, diff in pairs(active_diffs) do
    if vim.api.nvim_buf_is_valid(diff.proposed_bufnr) then
      -- Deleting the buffer triggers BufWipeout → reject_diff closure
      vim.api.nvim_buf_delete(diff.proposed_bufnr, { force = true })
      return
    end
  end
  log.warn("No active diff to reject")
end

--- Return the map of active diffs (for testing/debugging).
-- @return table
function M.get_active_diffs()
  return active_diffs
end

return M
