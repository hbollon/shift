--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Commands = require("../shift/lib/commands.luau")

-- A host whose state channel can lose events, like a saturated entry queue (spike S5).
local function lossyHost()
  local host = FakeHost.new({ nowMs = 1000 })
  local set = host.state.set
  host.drop = {} -- key -> number of upcoming sets to lose
  host.state.set = function(key, value)
    if (host.drop[key] or 0) > 0 then
      host.drop[key] -= 1
      return
    end
    set(key, value)
  end
  return host
end

local function service(host, handler)
  local handled = {}
  Commands.receiver(host, function(cmd, from)
    table.insert(handled, { type = cmd.type, seq = cmd.seq, from = from })
    return handler and handler(cmd) or { ok = true }
  end)
  return handled
end

t.describe("commands", function()
  t.it("delivers and acknowledges a command", function()
    local host = lossyHost()
    local handled = service(host)
    local sender = Commands.sender(host, "bar")
    t.expect(sender.send({ type = "checkin" })).toBe(1)
    t.expect(handled).toEqual({ { type = "checkin", seq = 1, from = sender.from } })
    t.expect(sender.pendingCount()).toBe(0)
    t.expect(host.state.get(Commands.ACK_KEY)[sender.from]).toEqual({ seq = 1, ok = true })
  end)

  t.it("gives every sender its own id", function()
    local host = lossyHost()
    local a, b = Commands.sender(host, "bar"), Commands.sender(host, "bar")
    t.expect(a.from == b.from).toBe(false)
    t.expect(string.match(a.from, "^bar%.%x+%-%x+$")).toBeTruthy()
  end)

  t.it("retries a command whose delivery was lost", function()
    local host = lossyHost()
    local handled = service(host)
    local sender = Commands.sender(host, "bar")
    host.drop[Commands.KEY] = 1
    sender.send({ type = "checkout" })
    t.expect(#handled).toBe(0)
    host.clock.advance(500)
    sender.tick()
    t.expect(#handled).toBe(0) -- not yet due
    host.clock.advance(500)
    sender.tick()
    t.expect(#handled).toBe(1)
    t.expect(sender.pendingCount()).toBe(0)
  end)

  t.it("handles a command once when only its acknowledgement was lost", function()
    local host = lossyHost()
    local handled = service(host)
    local sender = Commands.sender(host, "bar")
    host.drop[Commands.ACK_KEY] = 1
    sender.send({ type = "checkin" })
    t.expect(sender.pendingCount()).toBe(1)
    host.clock.advance(1000)
    sender.tick()
    t.expect(#handled).toBe(1)
    t.expect(sender.pendingCount()).toBe(0)
  end)

  t.it("keeps several senders apart on the shared key", function()
    local host = lossyHost()
    local handled = service(host)
    local bar, tile = Commands.sender(host, "bar"), Commands.sender(host, "tile")
    bar.send({ type = "checkin" })
    tile.send({ type = "checkout" })
    bar.send({ type = "toggle" })
    t.expect(#handled).toBe(3)
    t.expect(handled[3]).toEqual({ type = "toggle", seq = 2, from = bar.from })
    t.expect(bar.pendingCount() + tile.pendingCount()).toBe(0)
  end)

  t.it("gives up after five attempts", function()
    local host = lossyHost()
    local failures = {}
    local sender = Commands.sender(host, "bar", function(cmd, err)
      table.insert(failures, { cmd.type, err })
    end)
    host.drop[Commands.KEY] = 5
    service(host)
    sender.send({ type = "checkin" })
    for _ = 1, 5 do
      host.clock.advance(1000)
      sender.tick()
    end
    t.expect(failures).toEqual({ { "checkin", "timeout" } })
    t.expect(sender.pendingCount()).toBe(0)
  end)

  t.it("reports a command rejected by the service", function()
    local host = lossyHost()
    service(host, function()
      return { ok = false, error = "unknown_command" }
    end)
    local failures = {}
    local sender = Commands.sender(host, "bar", function(cmd, err)
      table.insert(failures, { cmd.type, err })
    end)
    sender.send({ type = "explode" })
    t.expect(failures).toEqual({ { "explode", "unknown_command" } })
  end)

  t.it("acknowledges a handler error so the sender stops retrying", function()
    local host = lossyHost()
    service(host, function()
      error("boom")
    end)
    local failures = {}
    local sender = Commands.sender(host, "bar", function(_, err)
      table.insert(failures, err)
    end)
    sender.send({ type = "checkin" })
    t.expect(failures).toEqual({ "internal" })
    t.expect(#host.logs).toBe(1)
  end)

  t.it("ignores malformed messages", function()
    local host = lossyHost()
    local handled = service(host)
    host.state.set(Commands.KEY, "nope")
    host.state.set(Commands.KEY, { from = "x", cmds = { { type = "checkin" } } })
    t.expect(#handled).toBe(0)
  end)
end)

t.finish()
