# CLAUDE.md — Instructions for AI Agents

This file provides guidance for AI coding assistants (Claude Code, Gemini CLI, etc.)
working on the `gemini-code.nvim` repository.

## Project Overview

`gemini-code.nvim` is a pure-Lua Neovim plugin that integrates the Gemini CLI
as a full IDE companion, following Google's official IDE Companion Spec
(MCP over HTTP).

## Architecture Summary

```
plugin/geminicode.lua          Entry point, user commands
lua/geminicode/
  init.lua                     Public API: setup(), start(), stop(), …
  config.lua                   Config defaults + validation
  log.lua                      Leveled logger (trace/debug/info/warn/error)
  discovery.lua                Creates/deletes the JSON discovery file
  context.lua                  Autocmd-based context tracker + contextUpdate
  diff.lua                     Native Neovim diff view + accept/reject
  terminal.lua                 Terminal spawner (snacks or native)
  server/
    init.lua                   Orchestrates tcp + http + mcp
    tcp.lua                    vim.loop TCP server (port 0)
    http.lua                   Minimal HTTP/1.1 parser
    auth.lua                   Bearer token generation + validation
    mcp.lua                    JSON-RPC 2.0 dispatcher
  tools/
    init.lua                   Tool registry bootstrap
    open_diff.lua              openDiff MCP tool
    close_diff.lua             closeDiff MCP tool
tests/
  server_spec.lua
  discovery_spec.lua
  context_spec.lua
  diff_spec.lua
```

## Key Design Decisions

1. **Pure Lua, zero external runtime dependencies** — only `folke/snacks.nvim`
   is an optional soft dependency (for enhanced terminal).

2. **Transport: HTTP/1.1** — each CLI request is a separate HTTP POST /mcp.
   This is simpler than WebSocket (no handshake, no framing).

3. **MCP over HTTP** — JSON-RPC 2.0 wrapped in plain HTTP.  The same
   `mcp.lua` module handles both incoming requests and queues outgoing
   notifications.

4. **vim.loop (libuv)** — all network I/O uses `vim.loop` (libuv).
   **Important:** Any Neovim API call inside a libuv callback MUST be wrapped
   in `vim.schedule(function() … end)`.

5. **Discovery file** — located at
   `{os.tmpdir()}/gemini/ide/gemini-ide-server-{PID}-{PORT}.json`.
   Must be created after the TCP server is bound (so the port is known) and
   deleted on plugin stop.

6. **Auth** — every HTTP request must carry `Authorization: Bearer <token>`.
   The token is a random UUID generated at server start and stored in the
   discovery file.

## Common Pitfalls

- `vim.loop` callbacks run in a libuv thread.  Always use `vim.schedule()`
  before calling any `vim.api.*` or `vim.fn.*` functions.
- The TCP server binds to port `0`; the actual port is only available after
  calling `server:bind()` via `server:getsockname().port`.
- The discovery file directory (`/tmp/gemini/ide/`) may not exist — always
  call `vim.fn.mkdir(dir, "p")` before writing.
- HTTP body buffering: the parser accumulates bytes until `Content-Length`
  bytes are received.  Do not assume a single TCP read delivers the full body.

## Running Tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) busted runner:

```sh
nvim --headless -u NONE \
  -c "set rtp+=path/to/plenary.nvim" \
  -c "lua require('plenary.busted').run('tests/')" \
  -c "qa!"
```

Or with `busted` directly if configured.

## Coding Style

- Lua 5.1 compatible (LuaJIT as used by Neovim).
- Module pattern: each file returns a table `M`.
- No globals except `vim` (provided by Neovim).
- Prefer `vim.tbl_deep_extend("force", …)` for config merging.
- All public functions have a leading `---` doc comment with `@param`/`@return`.

## Spec Reference

- IDE Companion Spec: https://geminicli.com/docs/ide-integration/ide-companion-spec/
- MCP Specification:  https://modelcontextprotocol.io/specification/2025-06-18/basic/index
- Reference impl:     https://github.com/coder/claudecode.nvim
