# gemini-code.nvim

A Neovim plugin that integrates [Gemini CLI](https://github.com/google-gemini/gemini-cli)
as a full IDE companion — giving Gemini full awareness of your open files,
cursor position, text selections, and native diff accept/reject — using
Google's official [IDE Companion Spec](https://geminicli.com/docs/ide-integration/ide-companion-spec/).

> **Status:** Early development.  Core protocol is implemented; tested manually
> against Gemini CLI.

---

## Features

- **Full IDE context** — Gemini sees your open files, cursor position, and
  selected text in real time
- **Native diff view** — proposed changes open as a standard Neovim diff split;
  accept with `:w`, reject by closing
- **MCP over HTTP** — implements Google's official IDE companion protocol
  (not just a terminal wrapper)
- **Zero mandatory dependencies** — pure Lua, no external libraries required
- **Optional snacks.nvim** — enhanced terminal via [folke/snacks.nvim](https://github.com/folke/snacks.nvim)

---

## Requirements

- Neovim >= 0.8.0
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) installed and in `$PATH`

### Optional

- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) for an enhanced terminal experience

---

## Installation

### lazy.nvim

```lua
{
  "beloin/gemini-code.nvim",
  config = function()
    require("geminicode").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "beloin/gemini-code.nvim",
  config = function()
    require("geminicode").setup()
  end,
}
```

---

## Configuration

All options and their defaults:

```lua
require("geminicode").setup({
  -- Automatically start the MCP server when the plugin loads
  auto_start = true,

  -- Log level: "trace" | "debug" | "info" | "warn" | "error"
  log_level = "info",

  -- Command to launch the Gemini CLI
  terminal_cmd = "gemini",

  -- IDE identification sent in the discovery file
  ide_info = {
    name         = "neovim",
    display_name = "Neovim",
  },

  -- Terminal window settings
  terminal = {
    split_side             = "right",   -- "left" | "right"
    split_width_percentage = 0.35,
    provider               = "auto",    -- "auto" | "snacks" | "native"
    auto_close             = true,
  },

  -- Diff view settings
  diff_opts = {
    auto_close_on_accept = true,
    vertical_split       = true,
    open_in_current_tab  = true,
  },

  -- Context tracking
  context = {
    debounce_ms          = 50,
    max_files            = 10,
    max_selection_bytes  = 16384,
  },
})
```

---

## Commands

| Command | Description |
|---|---|
| `:GeminiCode` | Toggle the Gemini CLI terminal |
| `:GeminiCodeFocus` | Focus (or open) the terminal |
| `:GeminiCodeAdd [path]` | Add a file to Gemini's context |
| `:'<,'>GeminiCodeSend` | Send visual selection to terminal |
| `:GeminiCodeDiffAccept` | Accept the current proposed diff |
| `:GeminiCodeDiffDeny` | Reject the current proposed diff |

---

## How It Works

```
Neovim                              Gemini CLI
  │                                     │
  ├─ plugin loads → start HTTP server   │
  ├─ write /tmp/gemini/ide/             │
  │    gemini-ide-server-PID-PORT.json  │
  │                                     │
  │  :GeminiCode                        │
  ├─ spawn gemini process ──────────────┤
  │   (GEMINI_CLI_IDE_SERVER_PORT=PORT) │
  │                                     │
  │                          reads discovery file
  │                          POST /mcp  { initialize }
  │◄────────────────────────────────────┤
  ├─ respond with capabilities + tools  │
  │                                     │
  │  (user edits / moves cursor)        │
  │                          ide/contextUpdate notification
  ├────────────────────────────────────►│
  │                                     │
  │                          tools/call openDiff
  │◄────────────────────────────────────┤
  ├─ open native diff view              │
  │                                     │
  │  (user presses :w in diff)          │
  │                          ide/diffAccepted notification
  ├────────────────────────────────────►│
```

### Discovery file

The plugin writes a JSON file that the CLI reads to find the server:

```json
{
  "port": 38291,
  "workspacePath": "/home/user/myproject",
  "authToken": "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx",
  "ideInfo": { "name": "neovim", "displayName": "Neovim" }
}
```

Location: `{os.tmpdir()}/gemini/ide/gemini-ide-server-{PID}-{PORT}.json`

---

## Accepting / Rejecting Diffs

When Gemini proposes a file change, a vertical split diff opens automatically:

```
┌────────────────────┬─────────────────────┐
│  current file      │  Gemini proposed    │
│  (left / original) │  (right / proposed) │
│                    │                     │
│  :w in proposed    →  accept + notify    │
│  :q in proposed    →  reject + notify    │
└────────────────────┴─────────────────────┘
```

Keymaps (in the proposed buffer):
- `<leader>da` — accept the diff
- `<leader>dr` — reject the diff

Or use the commands `:GeminiCodeDiffAccept` / `:GeminiCodeDiffDeny`.

---

## Differences from claudecode.nvim

| | claudecode.nvim | gemini-code.nvim |
|---|---|---|
| Transport | WebSocket (RFC 6455) | HTTP/1.1 |
| Discovery file | `~/.claude/ide/[port].lock` | `tmpdir/gemini/ide/gemini-ide-server-PID-PORT.json` |
| Auth | UUID in lock file | Bearer token in HTTP header |
| Context push | WS notification | HTTP notification |
| Diff tools | via WebSocket | via HTTP POST |
| PID in discovery | No | Yes (in filename) |

---

## Contributing

1. Fork the repo
2. Create a branch: `git checkout -b feature/my-feature`
3. Write Lua, test with `busted tests/` or manually
4. Open a PR

See [CLAUDE.md](CLAUDE.md) for architecture notes aimed at AI assistants.

---

## License

MIT — see [LICENSE](LICENSE).
