--- Configuration module for gemini-code.nvim
-- Provides defaults and config validation/merging.
-- @module geminicode.config

local M = {}

--- Default configuration values
M.defaults = {
  --- Automatically start the server when the plugin loads
  auto_start = true,

  --- Log level: "trace" | "debug" | "info" | "warn" | "error"
  log_level = "info",

  --- Command to launch the Gemini CLI
  terminal_cmd = "gemini",

  --- IDE identification sent in the discovery file
  ide_info = {
    name         = "neovim",
    display_name = "Neovim",
  },

  --- Terminal provider settings
  terminal = {
    --- Which side to open the terminal split: "left" | "right"
    split_side = "right",
    --- Width of the terminal as a fraction of the total window width
    split_width_percentage = 0.35,
    --- Provider: "auto" | "snacks" | "native"
    provider = "auto",
    --- Close terminal buffer automatically when the process exits
    auto_close = true,
  },

  --- Diff view settings
  diff_opts = {
    --- Automatically close the diff view when the user accepts
    auto_close_on_accept = true,
    --- Open diff in a vertical split (false = horizontal)
    vertical_split = true,
    --- Open the diff in the current tab instead of a new one
    open_in_current_tab = true,
  },

  --- Context tracking settings
  context = {
    --- Debounce interval in milliseconds before sending ide/contextUpdate
    debounce_ms = 50,
    --- Maximum number of open files to include in context
    max_files = 10,
    --- Maximum bytes of selected text to include in context
    max_selection_bytes = 16384,
  },
}

--- Active (merged) configuration
M.options = {}

--- Validate and merge user-provided config over defaults.
-- @param user_config table User-provided configuration table (may be nil)
-- @return table Merged configuration
function M.setup(user_config)
  user_config = user_config or {}

  -- Deep merge: user values override defaults
  M.options = vim.tbl_deep_extend("force", M.defaults, user_config)

  -- Validate log_level
  local valid_levels = { trace = true, debug = true, info = true, warn = true, error = true }
  if not valid_levels[M.options.log_level] then
    vim.notify(
      "[geminicode] Invalid log_level '" .. tostring(M.options.log_level) .. "', defaulting to 'info'",
      vim.log.levels.WARN
    )
    M.options.log_level = "info"
  end

  -- Validate terminal.provider
  local valid_providers = { auto = true, snacks = true, native = true }
  if not valid_providers[M.options.terminal.provider] then
    vim.notify(
      "[geminicode] Invalid terminal.provider '" .. tostring(M.options.terminal.provider) .. "', defaulting to 'auto'",
      vim.log.levels.WARN
    )
    M.options.terminal.provider = "auto"
  end

  -- Validate split_side
  local valid_sides = { left = true, right = true }
  if not valid_sides[M.options.terminal.split_side] then
    vim.notify(
      "[geminicode] Invalid terminal.split_side '" .. tostring(M.options.terminal.split_side) .. "', defaulting to 'right'",
      vim.log.levels.WARN
    )
    M.options.terminal.split_side = "right"
  end

  return M.options
end

return M
