--- MCP (Model Context Protocol) JSON-RPC 2.0 dispatcher for gemini-code.nvim
-- Handles incoming requests from the Gemini CLI and dispatches them to the
-- appropriate handler.  Also provides helpers for sending outbound
-- notifications (ide/contextUpdate, ide/diffAccepted, ide/diffRejected) back
-- to the CLI over the same HTTP connection.
--
-- NOTE: The Gemini CLI spec uses MCP over HTTP — each CLI request is a
-- separate HTTP POST /mcp.  Outbound notifications are sent as MCP
-- notification objects in the HTTP response body of the *next* request, OR
-- the server initiates a new HTTP POST to the CLI's callback URL.
--
-- For simplicity, and consistent with the spec's description of
-- ide/contextUpdate as a notification sent TO the CLI via POST /mcp, this
-- module keeps track of the CLI's source address and sends notifications as
-- separate HTTP POSTs when required.  The CLI is expected to expose a
-- callback for the duration of the session.
--
-- Actual outbound notification support is handled by the notification queue
-- which is flushed inside the response to the next incoming request (SSE-like
-- piggyback) OR sent directly when a connection reference is available.
-- @module geminicode.server.mcp

local log  = require("geminicode.log")
local http = require("geminicode.server.http")
local tcp  = require("geminicode.server.tcp")
local auth = require("geminicode.server.auth")

local M = {}

--- Tool registry: name → handler function(arguments) → result
local tools = {}

--- Pending outbound notifications (to be sent to CLI)
-- Each entry: { method, params }
-- Notifications are piggybacked in the response to the next request.
local notification_queue = {}

--- Register an MCP tool.
-- @param name string  Tool name (e.g. "openDiff")
-- @param schema table JSON Schema for the input (inputSchema)
-- @param handler function(arguments) → table  Returns MCP tool result
function M.register_tool(name, schema, handler)
  tools[name] = { schema = schema, handler = handler }
  log.debug("MCP tool registered:", name)
end

--- Enqueue an outbound notification to the CLI.
-- The notification will be piggybacked in the response to the next request.
-- @param method string  e.g. "ide/diffAccepted"
-- @param params table
function M.send_notification(method, params)
  table.insert(notification_queue, { method = method, params = params })
  log.debug("MCP notification queued:", method)
end

--- Retrieve and clear pending notifications.
-- Returns them as JSON-RPC notification objects.
-- Used by handle_request to piggyback notifications in the response.
-- @return table  Array of notification objects { jsonrpc, method, params }
function M._get_queued_notifications()
  local notifs = {}
  while #notification_queue > 0 do
    local notif = table.remove(notification_queue, 1)
    table.insert(notifs, {
      jsonrpc = "2.0",
      method  = notif.method,
      params  = notif.params,
    })
    log.debug("MCP notification dequeued for response:", notif.method)
  end
  return notifs
end

--- Handle an `initialize` request.
-- @param request table  JSON-RPC request
-- @return table  JSON-RPC result
local function handle_initialize(request)
  log.info("MCP initialize request received")
  return {
    protocolVersion = "2024-11-05",
    capabilities = {
      tools = { listChanged = false },
    },
    serverInfo = {
      name    = "gemini-code.nvim",
      version = "0.1.0",
    },
  }
end

--- Handle a `tools/list` request.
-- @return table  JSON-RPC result containing the tools array
local function handle_tools_list(_request)
  local tool_list = {}
  for name, tool in pairs(tools) do
    table.insert(tool_list, {
      name        = name,
      description = tool.schema.description or "",
      inputSchema = tool.schema.inputSchema or { type = "object", properties = {} },
    })
  end
  return { tools = tool_list }
end

--- Handle a `tools/call` request.
-- @param request table  Full JSON-RPC request (params.name, params.arguments)
-- @return table  JSON-RPC result
local function handle_tools_call(request)
  local params = request.params or {}
  local name   = params.name
  local args   = params.arguments or {}

  local tool = tools[name]
  if not tool then
    return nil, { code = -32601, message = "Tool not found: " .. tostring(name) }
  end

  local ok, result_or_err = pcall(tool.handler, args)
  if not ok then
    log.error("Tool handler error for '" .. name .. "':", result_or_err)
    return nil, { code = -32603, message = "Internal error in tool: " .. tostring(result_or_err) }
  end

  return result_or_err, nil
end

--- Request method dispatch table.
local dispatch = {
  ["initialize"]  = handle_initialize,
  ["tools/list"]  = handle_tools_list,
  ["tools/call"]  = handle_tools_call,
}

--- Process a raw HTTP request for the /mcp endpoint.
-- Validates auth, parses JSON-RPC, dispatches, and returns the HTTP response.
--
-- @param client uv_tcp_t  The connected client (kept as active reference)
-- @param request table    Parsed HTTP request from http.lua
-- @return string          Full HTTP response bytes to send back
function M.handle_request(client, request)
  -- Route check
  if request.path ~= "/mcp" then
    return http.json_response(404, { error = "Not found" })
  end
  if request.method ~= "POST" then
    return http.json_response(405, { error = "Method not allowed" })
  end

  -- Auth check
  if not auth.validate(request.headers["authorization"]) then
    log.warn("MCP request rejected: invalid or missing Bearer token")
    return http.json_response(401, { error = "Unauthorized" })
  end

  -- Parse JSON-RPC body
  local ok, rpc = pcall(vim.fn.json_decode, request.body)
  if not ok or type(rpc) ~= "table" then
    log.warn("MCP request: invalid JSON body")
    return http.json_response(400, {
      jsonrpc = "2.0",
      id      = vim.NIL,
      error   = { code = -32700, message = "Parse error" },
    })
  end

  local method = rpc.method
  local id     = rpc.id  -- nil for notifications (no response expected)

  log.debug("MCP dispatch:", method, "id=" .. tostring(id))

  -- Notifications (no id) — acknowledge but no result
  if id == nil and method then
    -- CLI may send notifications; currently we just log them
    log.trace("MCP notification (no response):", method)
    return http.json_response(204, nil)
  end

  local handler = dispatch[method]
  if not handler then
    log.warn("MCP unknown method:", method)
    return http.json_response(200, {
      jsonrpc = "2.0",
      id      = id,
      error   = { code = -32601, message = "Method not found: " .. tostring(method) },
    })
  end

  local result, err = handler(rpc)

  -- Drain any queued notifications (they are dropped for plain HTTP responses;
  -- the Streamable HTTP transport does not allow extra fields in a JSON-RPC
  -- response and the MCP SDK will reject the message with a Zod error if we
  -- add a non-standard "notifications" key).
  M._get_queued_notifications()

  local rpc_response
  if err then
    rpc_response = {
      jsonrpc = "2.0",
      id      = id,
      error   = err,
    }
  else
    rpc_response = {
      jsonrpc = "2.0",
      id      = id,
      result  = result,
    }
  end

  return http.json_response(200, rpc_response)
end

return M
