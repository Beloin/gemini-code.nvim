--- Minimal HTTP/1.1 parser and response writer for gemini-code.nvim
-- The Gemini CLI only sends simple POST /mcp requests, so this parser is
-- intentionally minimal: it handles request-line, headers, and a fixed-length
-- body (Content-Length is required).
-- @module geminicode.server.http

local log = require("geminicode.log")

local M = {}

--- Per-connection parser state.
-- Each client connection gets its own state table so that partial reads are
-- handled correctly.
-- @return table  Fresh parser state
function M.new_parser()
  return {
    -- Raw bytes received but not yet processed
    buf = "",
    -- Parsed request (nil until headers are complete)
    request = nil,
    -- Number of body bytes received so far
    body_received = 0,
  }
end

--- Parse HTTP request line and headers from the buffer.
-- Returns nil if the header section is not yet complete (no CRLFCRLF yet).
-- @param buf string  Raw bytes received so far
-- @return table|nil, string  parsed_head, remaining_bytes
local function parse_head(buf)
  -- Headers end at the first blank line (CRLFCRLF or LFLF)
  local header_end, body_start = buf:find("\r\n\r\n")
  if not header_end then
    -- Try Unix-style line endings as a fallback
    header_end, body_start = buf:find("\n\n")
    if not header_end then
      return nil, buf
    end
  end

  local head = buf:sub(1, header_end - 1)
  local rest = buf:sub(body_start + 1)

  local lines = vim.split(head, "\r\n")
  if #lines == 0 then
    lines = vim.split(head, "\n")
  end

  -- Parse the request line: METHOD PATH HTTP/VERSION
  local method, path, version = lines[1]:match("^(%S+)%s+(%S+)%s+(HTTP/%S+)$")
  if not method then
    return nil, buf  -- malformed
  end

  -- Parse headers into a lowercase-keyed map
  local headers = {}
  for i = 2, #lines do
    local name, value = lines[i]:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end

  return {
    method  = method,
    path    = path,
    version = version,
    headers = headers,
    body    = "",
  }, rest
end

--- Feed raw bytes into the per-connection parser state.
-- Calls `on_request(request)` when a full request (including body) is ready.
--
-- @param state table       Parser state from M.new_parser()
-- @param data  string      Raw bytes from the TCP layer
-- @param on_request function(request)  Callback with a completed request table
function M.feed(state, data, on_request)
  state.buf = state.buf .. data

  -- If we haven't finished parsing headers yet, try now
  if not state.request then
    local req, rest = parse_head(state.buf)
    if not req then
      -- Headers incomplete — wait for more data
      return
    end
    state.request = req
    state.buf = rest
    state.body_received = 0
  end

  local req = state.request

  -- Determine expected body length
  local content_length = tonumber(req.headers["content-length"]) or 0

  -- Accumulate body bytes
  local needed = content_length - state.body_received
  if needed > 0 then
    local chunk = state.buf:sub(1, needed)
    req.body = req.body .. chunk
    state.body_received = state.body_received + #chunk
    state.buf = state.buf:sub(needed + 1)
  end

  if state.body_received >= content_length then
    -- Full request received — deliver it
    local completed = state.request
    state.request = nil
    state.body_received = 0

    log.trace("HTTP request:", completed.method, completed.path, "body_len=" .. #completed.body)
    on_request(completed)
  end
end

--- Build and return an HTTP/1.1 response string.
-- @param status_code integer  e.g. 200, 401, 404
-- @param body string          Response body (may be empty)
-- @param content_type string  Defaults to "application/json"
-- @return string  Full HTTP response bytes
function M.response(status_code, body, content_type)
  content_type = content_type or "application/json"
  body = body or ""

  local reason = ({
    [200] = "OK",
    [204] = "No Content",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [500] = "Internal Server Error",
  })[status_code] or "Unknown"

  local headers = table.concat({
    "HTTP/1.1 " .. tostring(status_code) .. " " .. reason,
    "Content-Type: " .. content_type,
    "Content-Length: " .. tostring(#body),
    "Connection: close",
    "",
    "",
  }, "\r\n")

  return headers .. body
end

--- Convenience: respond with a JSON body.
-- @param status_code integer
-- @param tbl table  Will be JSON-encoded
-- @return string
function M.json_response(status_code, tbl)
  local ok, encoded = pcall(vim.fn.json_encode, tbl)
  if not ok then
    log.error("Failed to JSON-encode response:", encoded)
    encoded = "{}"
  end
  return M.response(status_code, encoded, "application/json")
end

return M
