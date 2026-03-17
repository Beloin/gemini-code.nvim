--- Diff view module for gemini-code.nvim
-- Opens a native Neovim vertical diff view when the Gemini CLI proposes
-- file changes.  Sends ide/diffAccepted or ide/diffRejected notifications
-- back to the CLI when the user acts on the diff.
-- @module geminicode.diff

local log = require("geminicode.log")
local mcp = require("geminicode.server.mcp")

local M = {}

--- Map of filePath → { original_bufnr, proposed_bufnr, accepted }
local active_diffs = {}

--- Configuration (set from diff_opts in config)
local opts = {
  auto_close_on_accept = true,
  vertical_split       = true,
  open_in_current_tab  = true,
}

--- Configure diff behaviour.
-- @param diff_opts table  Values from config.diff_opts
function M.setup(diff_opts)
  opts = vim.tbl_deep_extend("force", opts, diff_opts or {})
end

--- Open a diff view for the given file.
-- Called by the openDiff tool handler.
--
-- @param file_path  string  Absolute path to the file being changed
-- @param new_content string The proposed new content from the CLI
-- @return boolean, string|nil  success, error
function M.open(file_path, new_content)
  if active_diffs[file_path] then
    -- Already showing a diff for this file — close the old one first
    M.close(file_path)
  end

  -- Load (or find) the original buffer
  local orig_bufnr = vim.fn.bufadd(file_path)
  vim.fn.bufload(orig_bufnr)

  -- Create a scratch buffer for the proposed content
  local proposed_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(proposed_bufnr, "buftype", "acwrite")  -- triggers BufWriteCmd
  vim.api.nvim_buf_set_option(proposed_bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_name(proposed_bufnr, file_path .. " [Gemini Proposed]")

  -- Split the proposed content into lines
  local lines = vim.split(new_content, "\n", { plain = true })
  -- Remove trailing empty line that split() adds for a trailing newline
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(proposed_bufnr, 0, -1, false, lines)

  -- Remember the diff state
  active_diffs[file_path] = {
    original_bufnr = orig_bufnr,
    proposed_bufnr = proposed_bufnr,
    accepted       = false,
  }

  -- Open the diff windows
  vim.schedule(function()
    -- Ensure original file is visible in current window
    vim.api.nvim_set_current_buf(orig_bufnr)
    vim.cmd("diffthis")

    -- Open the proposed buffer in a split
    local split_cmd = opts.vertical_split and "vsplit" or "split"
    vim.cmd(split_cmd)
    vim.api.nvim_set_current_buf(proposed_bufnr)
    vim.cmd("diffthis")

    -- --- Keymaps and autocmds on the proposed buffer ---

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

      if opts.auto_close_on_accept then
        M.close(file_path)
      end
    end

    local function reject_diff()
      if not active_diffs[file_path] then return end
      if not active_diffs[file_path].accepted then
        mcp.send_notification("ide/diffRejected", { filePath = file_path })
        log.info("Diff rejected:", file_path)
      end
      active_diffs[file_path] = nil
      -- Clean up diff mode on original buffer
      vim.api.nvim_buf_call(orig_bufnr, function()
        vim.cmd("diffoff")
      end)
    end

    -- BufWriteCmd on the proposed buffer → accept
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer   = proposed_bufnr,
      once     = true,
      callback = function()
        accept_diff()
      end,
    })

    -- BufWipeout on the proposed buffer → reject (if not already accepted)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer   = proposed_bufnr,
      once     = true,
      callback = reject_diff,
    })

    -- Convenience keymaps in the proposed buffer
    local km_opts = { noremap = true, silent = true, buffer = proposed_bufnr }
    vim.keymap.set("n", "<leader>da", accept_diff, vim.tbl_extend("force", km_opts, { desc = "Accept Gemini diff" }))
    vim.keymap.set("n", "<leader>dr", function()
      vim.api.nvim_buf_delete(proposed_bufnr, { force = true })
    end, vim.tbl_extend("force", km_opts, { desc = "Reject Gemini diff" }))

    log.info("Diff view opened for:", file_path)
  end)

  return true, nil
end

--- Close the diff view for a given file path.
-- Called by the closeDiff tool handler or after accept.
-- @param file_path string
-- @return string|nil  Final content of the original buffer (for closeDiff response)
function M.close(file_path)
  local diff = active_diffs[file_path]
  if not diff then
    return nil
  end

  active_diffs[file_path] = nil

  -- Wipe the proposed buffer (triggers BufWipeout → reject if not accepted)
  local proposed = diff.proposed_bufnr
  if proposed and vim.api.nvim_buf_is_valid(proposed) then
    vim.api.nvim_buf_delete(proposed, { force = true })
  end

  -- Turn off diff mode on the original buffer
  local orig = diff.original_bufnr
  if orig and vim.api.nvim_buf_is_valid(orig) then
    vim.api.nvim_buf_call(orig, function()
      vim.cmd("diffoff")
    end)
    local lines = vim.api.nvim_buf_get_lines(orig, 0, -1, false)
    return table.concat(lines, "\n")
  end

  return nil
end

--- Accept the currently active diff for a file (called from user command).
-- @param file_path string|nil  Use current buffer path if nil
function M.accept(file_path)
  file_path = file_path or vim.api.nvim_buf_get_name(0)
  -- Find the diff that contains this path
  for fp, diff in pairs(active_diffs) do
    if fp == file_path or vim.api.nvim_buf_is_valid(diff.proposed_bufnr) then
      -- Trigger BufWriteCmd by writing the proposed buffer
      vim.api.nvim_buf_call(diff.proposed_bufnr, function()
        vim.cmd("write")
      end)
      return
    end
  end
  log.warn("No active diff to accept")
end

--- Reject the currently active diff for a file (called from user command).
-- @param file_path string|nil  Use current buffer path if nil
function M.reject(file_path)
  file_path = file_path or vim.api.nvim_buf_get_name(0)
  for fp, diff in pairs(active_diffs) do
    if fp == file_path or vim.api.nvim_buf_is_valid(diff.proposed_bufnr) then
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
