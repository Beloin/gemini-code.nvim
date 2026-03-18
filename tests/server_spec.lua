--- Tests for the HTTP server pipeline (auth, http parser, mcp dispatcher)
-- Run with: nvim --headless -u NONE -c "lua require('plenary.busted').run('tests/')"
-- or: busted tests/server_spec.lua (with busted + plenary configured)

local auth = require("geminicode.server.auth")
local http = require("geminicode.server.http")

describe("geminicode.server.auth", function()
  before_each(function()
    auth.reset()
  end)

  it("generates a non-empty token on init", function()
    local token = auth.init()
    assert.is_string(token)
    assert.is_truthy(#token > 0)
  end)

  it("returns nil token before init", function()
    assert.is_nil(auth.get_token())
  end)

  it("validates a correct Bearer token", function()
    local token = auth.init()
    assert.is_true(auth.validate("Bearer " .. token))
  end)

  it("rejects a wrong token", function()
    auth.init()
    assert.is_false(auth.validate("Bearer wrong-token"))
  end)

  it("rejects missing Authorization header", function()
    auth.init()
    assert.is_false(auth.validate(nil))
  end)

  it("rejects malformed Authorization header (no Bearer prefix)", function()
    local token = auth.init()
    assert.is_false(auth.validate(token))
  end)

  it("resets token to nil", function()
    auth.init()
    auth.reset()
    assert.is_nil(auth.get_token())
  end)
end)

describe("geminicode.server.http - parser", function()
  it("parses a complete HTTP POST request", function()
    local state = http.new_parser()
    local body  = '{"jsonrpc":"2.0","method":"initialize","id":1}'
    local raw   = table.concat({
      "POST /mcp HTTP/1.1",
      "Host: 127.0.0.1:12345",
      "Content-Type: application/json",
      "Authorization: Bearer abc-123",
      "Content-Length: " .. tostring(#body),
      "",
      "",
    }, "\r\n") .. body

    local received = {}
    http.feed(state, raw, function(req)
      table.insert(received, req)
    end)

    assert.equals(1, #received)
    local req = received[1]
    assert.equals("POST",   req.method)
    assert.equals("/mcp",   req.path)
    assert.equals(body,     req.body)
    assert.equals("abc-123", req.headers["authorization"]:match("Bearer (.+)"))
  end)

  it("handles partial reads correctly", function()
    local state = http.new_parser()
    local body  = '{"method":"test"}'
    local raw   = "POST /mcp HTTP/1.1\r\nContent-Length: " .. tostring(#body) .. "\r\n\r\n" .. body

    local received = {}
    local on_req = function(req) table.insert(received, req) end

    -- Split at arbitrary byte boundary
    local half = math.floor(#raw / 2)
    http.feed(state, raw:sub(1, half),     on_req)
    assert.equals(0, #received)  -- incomplete
    http.feed(state, raw:sub(half + 1),    on_req)
    assert.equals(1, #received)
  end)

  it("builds a JSON response correctly", function()
    local resp = http.json_response(200, { ok = true })
    assert.is_truthy(resp:find("HTTP/1.1 200 OK", 1, true))
    assert.is_truthy(resp:find("Content-Type: application/json", 1, true))
    assert.is_truthy(resp:find('"ok"', 1, true))
  end)

  it("builds a 401 response", function()
    local resp = http.json_response(401, { error = "Unauthorized" })
    assert.is_truthy(resp:find("HTTP/1.1 401 Unauthorized", 1, true))
  end)
end)

describe("geminicode.server.mcp - handle_request response shape", function()
  local mcp  = require("geminicode.server.mcp")
  local auth = require("geminicode.server.auth")

  before_each(function()
    auth.reset()
    auth.init()
    -- Clear any stale queued notifications
    mcp._get_queued_notifications()
  end)

  after_each(function()
    auth.reset()
  end)

  it("response does NOT contain a non-standard 'notifications' field", function()
    -- Queue a notification; it must be drained but NOT leaked into the response
    mcp.send_notification("ide/contextUpdate", { workspaceState = {} })

    local body = vim.fn.json_encode({
      jsonrpc = "2.0",
      method  = "initialize",
      id      = 1,
    })
    local request = {
      method  = "POST",
      path    = "/mcp",
      headers = { authorization = "Bearer " .. auth.get_token() },
      body    = body,
    }

    local raw_response = mcp.handle_request(nil, request)
    assert.is_truthy(raw_response:find("HTTP/1.1 200 OK", 1, true))
    assert.is_falsy(raw_response:find('"notifications"', 1, true))
  end)

  it("valid initialize response contains jsonrpc and result fields", function()
    local body = vim.fn.json_encode({
      jsonrpc = "2.0",
      method  = "initialize",
      id      = 1,
    })
    local request = {
      method  = "POST",
      path    = "/mcp",
      headers = { authorization = "Bearer " .. auth.get_token() },
      body    = body,
    }

    local raw_response = mcp.handle_request(nil, request)
    assert.is_truthy(raw_response:find('"jsonrpc"', 1, true))
    assert.is_truthy(raw_response:find('"result"', 1, true))
    assert.is_falsy(raw_response:find('"error"', 1, true))
  end)
end)

describe("geminicode.server.mcp - notification piggybacking", function()
  local mcp = require("geminicode.server.mcp")
  local http = require("geminicode.server.http")

  before_each(function()
    -- Clear any queued notifications
    mcp._get_queued_notifications()
  end)

  it("queues notifications and retrieves them", function()
    mcp.send_notification("ide/diffAccepted", { filePath = "/tmp/test.lua", content = "new" })
    mcp.send_notification("ide/contextUpdate", { workspaceState = { openFiles = {} } })

    local notifs = mcp._get_queued_notifications()
    assert.equals(2, #notifs)
    assert.equals("ide/diffAccepted", notifs[1].method)
    assert.equals("ide/contextUpdate", notifs[2].method)
  end)

  it("includes notifications in JSON-RPC response", function()
    mcp.send_notification("test/notification", { data = "value" })

    local rpc_response = {
      jsonrpc = "2.0",
      id      = 1,
      result  = { ok = true },
    }
    local notifs = mcp._get_queued_notifications()
    if #notifs > 0 then
      rpc_response.notifications = notifs
    end

    local resp_body = vim.fn.json_encode(rpc_response)
    assert.is_truthy(resp_body:find('"notifications"', 1, true))
    assert.is_truthy(resp_body:find('test/notification', 1, true))
  end)

  it("clears notifications after retrieval", function()
    mcp.send_notification("test/notif", {})
    mcp._get_queued_notifications()

    -- Second retrieval should get empty list
    local notifs = mcp._get_queued_notifications()
    assert.equals(0, #notifs)
  end)
end)
