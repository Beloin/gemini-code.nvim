--- Tests for geminicode.discovery
-- Verifies that the discovery JSON file is created and deleted correctly.

describe("geminicode.discovery", function()
  local auth      = require("geminicode.server.auth")
  local discovery = require("geminicode.discovery")

  before_each(function()
    auth.reset()
    auth.init()
    discovery.delete()  -- ensure clean slate
  end)

  after_each(function()
    discovery.delete()
    auth.reset()
  end)

  it("creates a discovery file with correct fields", function()
    local ok, err = discovery.create(38291, { name = "neovim", display_name = "Neovim" })
    assert.is_true(ok, tostring(err))

    local path = discovery.get_path()
    assert.is_string(path)
    assert.is_truthy(path:find("gemini%-ide%-server%-"))
    assert.is_truthy(path:find("38291"))

    -- Read and decode the file
    local fh = io.open(path, "r")
    assert.is_truthy(fh, "discovery file should exist")
    local content = fh:read("*a")
    fh:close()

    local data = vim.fn.json_decode(content)
    assert.equals(38291, data.port)
    assert.equals(auth.get_token(), data.authToken)
    assert.equals("neovim",   data.ideInfo.name)
    assert.equals("Neovim",   data.ideInfo.displayName)
    assert.is_string(data.workspacePath)
  end)

  it("deletes the discovery file", function()
    discovery.create(38291, { name = "neovim", display_name = "Neovim" })
    local path = discovery.get_path()
    assert.is_truthy(path)

    discovery.delete()
    assert.is_nil(discovery.get_path())

    local fh = io.open(path, "r")
    assert.is_nil(fh, "file should have been deleted")
  end)

  it("delete is idempotent (no error on double delete)", function()
    discovery.create(38291, { name = "neovim", display_name = "Neovim" })
    discovery.delete()
    assert.has_no.errors(function()
      discovery.delete()
    end)
  end)

  it("embeds PID in the filename", function()
    discovery.create(12345, { name = "neovim", display_name = "Neovim" })
    local path = discovery.get_path()
    local pid  = tostring(vim.fn.getpid())
    assert.is_truthy(path:find(pid), "path should contain the PID")
  end)
end)
