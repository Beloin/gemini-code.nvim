--- Authentication module for gemini-code.nvim
-- Generates a random UUID Bearer token at server startup and validates it
-- on every incoming HTTP request from the Gemini CLI.
-- @module geminicode.server.auth

local M = {}

--- @type string|nil  The active auth token for this session
local token = nil

--- Generate a random UUID v4 string.
-- Uses math.random seeded from os.time for simplicity (sufficient for a
-- single-session local token).
-- @return string  UUID in "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" format
local function uuid4()
  math.randomseed(os.time() + math.floor(vim.loop.hrtime() % 1000000))
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

--- Initialise (or re-initialise) the auth token.
-- Called once when the server starts.
-- @return string  The newly generated token
function M.init()
  token = uuid4()
  return token
end

--- Return the current auth token.
-- @return string|nil
function M.get_token()
  return token
end

--- Validate an HTTP Authorization header value.
-- Expected format: "Bearer <token>"
-- @param header_value string|nil  The value of the Authorization header
-- @return boolean  true if the token is valid
function M.validate(header_value)
  if not header_value or not token then
    return false
  end
  -- Must be exactly "Bearer <token>" (case-sensitive, single space)
  local bearer = header_value:match("^Bearer%s+(.+)$")
  if not bearer then
    return false
  end
  return bearer == token
end

--- Clear the token on server shutdown.
function M.reset()
  token = nil
end

return M
