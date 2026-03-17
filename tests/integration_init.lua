-- tests/integration_init.lua
-- Minimal Neovim init for the gemini-code.nvim integration demo.
--
-- Usage (via run_integration.sh or directly):
--   nvim -u tests/integration_init.lua
--
-- After Neovim opens:
--   :GeminiCode         → opens mock CLI (normal mode)
--   :GeminiCodeAutoEdit → opens mock CLI with --approval-mode=auto_edit

-- Add the plugin to the runtime path (works from any cwd)
local plugin_root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>")), ":h:h")
vim.opt.rtp:prepend(plugin_root)

require("geminicode").setup({
  auto_start   = true,
  log_level    = "debug",

  -- Point terminal_cmd at the mock CLI
  terminal_cmd = "python3 " .. plugin_root .. "/tests/mock_gemini_cli.py",

  terminal = {
    provider               = "native",
    split_side             = "right",
    split_width_percentage = 0.40,
    auto_close             = false,   -- keep terminal open to read output
  },

  diff_opts = {
    auto_close_on_accept = true,
    vertical_split       = true,
    open_in_current_tab  = true,
  },
})
