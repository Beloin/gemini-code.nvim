--- TCP server module for gemini-code.nvim
-- Creates a local TCP server using vim.loop (libuv) that binds to port 0
-- (OS-assigned dynamic port) and accepts HTTP connections from the Gemini CLI.
-- @module geminicode.server.tcp

local log = require("geminicode.log")

local M = {}

--- @type uv_tcp_t|nil
local server = nil

--- @type integer|nil  Assigned port after binding
local bound_port = nil

--- @type function|nil  Callback invoked with (client, data) on each received chunk
local on_data_cb = nil

--- @type function|nil  Callback invoked with (client) on new connection
local on_connect_cb = nil

--- Return the port the server is currently listening on.
-- @return integer|nil
function M.get_port()
  return bound_port
end

--- Start the TCP server.
-- Binds to 127.0.0.1:0 (OS picks a free port), begins listening.
--
-- @param opts table
--   opts.on_connect  function(client)          called for each new connection
--   opts.on_data     function(client, data)     called for each data chunk
-- @return boolean, string|nil  success, error message
function M.start(opts)
  opts = opts or {}
  on_connect_cb = opts.on_connect
  on_data_cb = opts.on_data

  local uv = vim.loop

  server = uv.new_tcp()
  if not server then
    return false, "Failed to create TCP handle"
  end

  -- Bind to loopback on port 0 — OS assigns an ephemeral port
  local ok, bind_err = server:bind("127.0.0.1", 0)
  if not ok then
    server:close()
    server = nil
    return false, "TCP bind failed: " .. tostring(bind_err)
  end

  -- Read back the actual assigned port
  local addr = server:getsockname()
  if not addr then
    server:close()
    server = nil
    return false, "Failed to get socket name after bind"
  end
  bound_port = addr.port

  -- Start listening (backlog = 128)
  local listen_ok, listen_err = server:listen(128, function(err)
    if err then
      vim.schedule(function()
        log.error("TCP listen error:", err)
      end)
      return
    end

    -- Accept the new client connection
    local client = uv.new_tcp()
    if not client then
      vim.schedule(function()
        log.error("Failed to create client TCP handle")
      end)
      return
    end

    local accept_ok, accept_err = server:accept(client)
    if not accept_ok then
      vim.schedule(function()
        log.error("TCP accept error:", accept_err)
      end)
      client:close()
      return
    end

    vim.schedule(function()
      log.trace("New TCP connection accepted")
      if on_connect_cb then
        on_connect_cb(client)
      end
    end)

    -- Start reading data from the client
    client:read_start(function(read_err, data)
      if read_err then
        vim.schedule(function()
          log.debug("TCP read error (client disconnected?):", read_err)
          if not client:is_closing() then
            client:close()
          end
        end)
        return
      end

      if data then
        vim.schedule(function()
          if on_data_cb then
            on_data_cb(client, data)
          end
        end)
      else
        -- EOF — client closed the connection
        vim.schedule(function()
          log.trace("TCP client disconnected (EOF)")
          if not client:is_closing() then
            client:close()
          end
        end)
      end
    end)
  end)

  if not listen_ok then
    server:close()
    server = nil
    bound_port = nil
    return false, "TCP listen failed: " .. tostring(listen_err)
  end

  log.info("TCP server listening on 127.0.0.1:" .. tostring(bound_port))
  return true, nil
end

--- Write data to a client socket.
-- @param client uv_tcp_t
-- @param data string
-- @param cb function|nil  optional callback(err)
function M.write(client, data, cb)
  if client:is_closing() then
    if cb then cb("client is closing") end
    return
  end
  client:write(data, function(err)
    if err then
      log.debug("TCP write error:", err)
    end
    if cb then cb(err) end
  end)
end

--- Close a client connection.
-- @param client uv_tcp_t
function M.close_client(client)
  if not client:is_closing() then
    client:close()
  end
end

--- Stop the TCP server and close all resources.
function M.stop()
  if server then
    if not server:is_closing() then
      server:close()
    end
    server = nil
  end
  bound_port = nil
  log.info("TCP server stopped")
end

--- Return whether the server is currently running.
-- @return boolean
function M.is_running()
  return server ~= nil and not server:is_closing()
end

return M
