--- Entry point for gemini-code.nvim
-- Registers Neovim user commands and triggers plugin setup.
-- No logic lives here — everything delegates to lua/geminicode/init.lua.

if vim.g.loaded_geminicode then
  return
end
vim.g.loaded_geminicode = true

-- Ensure minimum Neovim version
if vim.fn.has("nvim-0.8.0") == 0 then
  vim.notify(
    "[gemini-code.nvim] Requires Neovim >= 0.8.0",
    vim.log.levels.ERROR
  )
  return
end

-- ── User Commands ──────────────────────────────────────────────────────────

--- Toggle the Gemini CLI terminal (open / focus / hide)
vim.api.nvim_create_user_command("GeminiCode", function()
  require("geminicode").toggle_terminal()
end, {
  desc = "Toggle Gemini CLI terminal",
})

--- Toggle the Gemini CLI terminal with auto-edit mode (--approval-mode=auto_edit)
-- Skips diff approval for automatic changes
vim.api.nvim_create_user_command("GeminiCodeAutoEdit", function()
  require("geminicode").toggle_terminal_auto_edit()
end, {
  desc = "Toggle Gemini CLI with auto-edit mode (skips diff approval)",
})

--- Smart focus: open if not running, focus if open but not active, hide if active
vim.api.nvim_create_user_command("GeminiCodeFocus", function()
  require("geminicode").focus_terminal()
end, {
  desc = "Focus (or open) the Gemini CLI terminal",
})

--- Add a file to the IDE context sent to the CLI
-- Usage: :GeminiCodeAdd [path]  (defaults to current buffer)
vim.api.nvim_create_user_command("GeminiCodeAdd", function(args)
  local path = args.args ~= "" and args.args or nil
  require("geminicode").add_file(path)
end, {
  nargs = "?",
  complete = "file",
  desc = "Add a file to Gemini context",
})

--- Send the current visual selection to the Gemini terminal
vim.api.nvim_create_user_command("GeminiCodeSend", function()
  require("geminicode").send_selection()
end, {
  range = true,
  desc = "Send file reference for selection to Gemini terminal",
})

--- Accept the currently proposed diff
vim.api.nvim_create_user_command("GeminiCodeDiffAccept", function()
  require("geminicode").diff_accept()
end, {
  desc = "Accept the current Gemini-proposed diff",
})

--- Reject the currently proposed diff
vim.api.nvim_create_user_command("GeminiCodeDiffDeny", function()
  require("geminicode").diff_reject()
end, {
  desc = "Reject the current Gemini-proposed diff",
})
