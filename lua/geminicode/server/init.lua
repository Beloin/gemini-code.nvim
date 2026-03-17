--- Server orchestration module for gemini-code.nvim
-- Ties together the TCP layer, HTTP parser, auth, and MCP dispatcher.
-- @module geminicode.server

local log  = require("geminicode.log")
local tcp  = require("geminicode.server.tcp")
local http = require("geminicode.server.http")
local auth = require("geminicode.server.auth")
local mcp  = require("geminicode.server.mcp")

local M = {}

--- Per-client HTTP parser states: client handle → parser state table
local client_states = {}

--- Start the HTTP/MCP server.
-- Initialises auth, starts TCP, and wires up the HTTP/MCP pipeline.
-- @return boolean, string|nil  success, error message
function M.start()
  -- Generate authentication token
  auth.init()

  local ok, err = tcp.start({
    on_connect = function(client)
      -- Allocate a fresh HTTP parser state for each connection
      client_states[client] = http.new_parser()
      log.trace("Server: new client connection")
    end,

    on_data = function(client, data)
      local state = client_states[client]
      if not state then
        log.warn("Server: data from unknown client — ignoring")
        return
      end

      http.feed(state, data, function(request)
        -- Full HTTP request received — dispatch through MCP
        local response = mcp.handle_request(client, request)
        tcp.write(client, response, function(write_err)
          if not write_err then
            -- HTTP/1.1 close connection after each request (Connection: close)
            tcp.close_client(client)
            client_states[client] = nil
          end
        end)
      end)
    end,
  })

  if not ok then
    return false, err
  end

  log.info("MCP server started on port", tcp.get_port())
  return true, nil
end

--- Stop the server.
function M.stop()
  tcp.stop()
  auth.reset()
  client_states = {}
  log.info("MCP server stopped")
end

--- Return the listening port (nil if not started).
-- @return integer|nil
function M.get_port()
  return tcp.get_port()
end

--- Return whether the server is running.
-- @return boolean
function M.is_running()
  return tcp.is_running()
end

return M
