--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Idle = require("../shift/lib/signals/idle.luau")
local Logind = require("../shift/lib/signals/logind.luau")
local Stream = require("../shift/lib/signals/stream.luau")

local NOW_MS = 1791547320000

-- The marker of a stream, read from its wrapped command.
local function markerOf(stream)
  return string.match(stream.cmd, '^echo "(%S+) pid')
end

t.describe("signals.stream", function()
  t.it("wraps the command and passes its lines through", function()
    local host = FakeHost.new({ nowMs = NOW_MS })
    local lines = {}
    local stream = Stream.start(host, "test", "watch-thing", function(line)
      table.insert(lines, line)
    end)
    t.expect(stream.state()).toBe("running")
    local marker = markerOf(host.streams[1])
    t.expect(host.streams[1].cmd).toBe(string.format('echo "%s pid $$"; watch-thing; echo "%s exit $?"', marker, marker))
    host.streamLine(1, marker .. " pid 4242")
    host.streamLine(1, "hello")
    t.expect(lines).toEqual({ "hello" })
  end)

  t.it("stops the process group", function()
    local host = FakeHost.new({ nowMs = NOW_MS })
    local stream = Stream.start(host, "test", "watch-thing", function() end)
    host.streamLine(1, markerOf(host.streams[1]) .. " pid 4242")
    stream.stop()
    t.expect(host.commands[1].argv).toEqual({ "/bin/sh", "-c", "kill -TERM -- -4242" })
    t.expect(stream.state()).toBe("stopped")
  end)

  t.it("kills a run stopped before it reported its pid, and ignores its lines", function()
    local host = FakeHost.new({ nowMs = NOW_MS })
    local lines = {}
    local stream = Stream.start(host, "test", "watch-thing", function(line)
      table.insert(lines, line)
    end)
    stream.stop()
    t.expect(#host.commands).toBe(0)
    host.streamLine(1, markerOf(host.streams[1]) .. " pid 77")
    host.streamLine(1, "late")
    t.expect(host.commands[1].argv[3]).toBe("kill -TERM -- -77")
    t.expect(lines).toEqual({})
  end)

  t.it("restarts with backoff, then gives up for a while", function()
    local host = FakeHost.new({ nowMs = NOW_MS })
    local states = {}
    local stream = Stream.start(host, "test", "flaky", function() end, function(state)
      table.insert(states, state)
    end)
    local delays = {}
    for run = 1, 5 do
      host.streamLine(run, markerOf(host.streams[run]) .. " exit 1")
      t.expect(stream.state()).toBe("restarting")
      local before = #host.streams
      local waited = 0
      while #host.streams == before do
        host.clock.advance(500)
        waited += 500
        stream.tick()
      end
      table.insert(delays, waited)
    end
    t.expect(delays).toEqual({ 1000, 2000, 4000, 8000, 16000 })
    host.streamLine(6, markerOf(host.streams[6]) .. " exit 1")
    t.expect(stream.state()).toBe("failed")
    host.clock.advance(5 * 60 * 1000)
    stream.tick()
    t.expect(#host.streams).toBe(7)
    t.expect(states[#states]).toBe("running")
  end)
end)

t.describe("signals.idle", function()
  local function start(options)
    local host = FakeHost.new({ nowMs = NOW_MS, commands = options.commands or { swayidle = true } })
    local signals = {}
    local monitor = Idle.start(host, {
      backend = options.backend or "auto",
      timeoutS = 300,
      onSignal = function(signal, atS)
        table.insert(signals, { signal, atS })
      end,
    })
    return host, monitor, signals
  end

  t.it("runs swayidle with the timeout", function()
    local host, monitor = start({})
    t.expect((string.find(host.streams[1].cmd, "; swayidle -w timeout 300 'echo idle' resume 'echo active';", 1, true))).toBeTruthy()
    t.expect(monitor.health()).toBe("ok")
    t.expect(monitor.hint()).toBeNil()
  end)

  t.it("reports idle at once and active after the debounce delay", function()
    local host, monitor, signals = start({})
    host.streamLine(1, "idle")
    t.expect(signals).toEqual({ { "idle", NOW_MS // 1000 } })
    host.clock.advance(60 * 1000)
    host.streamLine(1, "active")
    monitor.tick()
    t.expect(#signals).toBe(1)
    host.clock.advance(2000)
    monitor.tick()
    t.expect(signals[2]).toEqual({ "active", (NOW_MS + 60 * 1000) // 1000 })
  end)

  t.it("drops an active followed by idle within 2 s", function()
    local host, monitor, signals = start({})
    host.streamLine(1, "idle")
    host.clock.advance(1000)
    host.streamLine(1, "active")
    host.clock.advance(170)
    host.streamLine(1, "idle")
    host.clock.advance(5000)
    monitor.tick()
    t.expect(#signals).toBe(1)
  end)

  t.it("asks for swayidle when it is missing", function()
    local host, monitor = start({ commands = {} })
    t.expect(#host.streams).toBe(0)
    t.expect(monitor.health()).toBe("unavailable")
    t.expect(monitor.hint()).toBe("swayidle")
  end)

  t.it("waits for IPC with the external backend", function()
    local host, monitor = start({ backend = "external" })
    t.expect(#host.streams).toBe(0)
    t.expect(monitor.health()).toBe("external")
    t.expect(monitor.hint()).toBeNil()
  end)
end)

t.describe("signals.logind", function()
  local SESSION = "/org/freedesktop/login1/session/_32"

  local function lockedLine(value)
    return string.format(
      "%s: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'IdleHint': <false>, 'LockedHint': <%s>}, @as [])",
      SESSION,
      value
    )
  end

  t.it("parses lock and sleep lines of our session only", function()
    t.expect(Logind.parse(lockedLine("true"), SESSION)).toBe("lock")
    t.expect(Logind.parse(lockedLine("false"), SESSION)).toBe("unlock")
    t.expect(Logind.parse(lockedLine("true"), "/org/freedesktop/login1/session/_7")).toBeNil()
    t.expect(Logind.parse("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)", SESSION)).toBe("sleep")
    t.expect(Logind.parse("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)", nil)).toBe("resume")
    t.expect(Logind.parse("/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', objectpath '/x')", SESSION)).toBeNil()
  end)

  local function start(options)
    local host = FakeHost.new({
      nowMs = NOW_MS,
      commands = options.commands or { gdbus = true, loginctl = true },
      env = options.env or { XDG_SESSION_ID = "2" },
    })
    local signals = {}
    local monitor = Logind.start(host, function(signal)
      table.insert(signals, signal)
    end)
    return host, monitor, signals
  end

  t.it("resolves the session, reads the lock state and monitors changes", function()
    local host, monitor, signals = start({})
    t.expect(host.commands[1].argv[#host.commands[1].argv]).toBe("2")
    host.finish(1, { stdout = "(objectpath '" .. SESSION .. "',)\n" })
    t.expect(host.streams[1].cmd).toBe(string.format(
      'echo "%s pid $$"; gdbus monitor --system --dest org.freedesktop.login1; echo "%s exit $?"',
      markerOf(host.streams[1]),
      markerOf(host.streams[1])
    ))
    t.expect(host.commands[2].argv[7]).toBe(SESSION)
    host.finish(2, { stdout = "(<false>,)\n" })
    t.expect(signals).toEqual({}) -- unlocked at start: nothing to report
    host.streamLine(1, lockedLine("true"))
    host.streamLine(1, lockedLine("true")) -- repeated hint
    host.streamLine(1, lockedLine("false"))
    t.expect(signals).toEqual({ "lock", "unlock" })
    t.expect(monitor.health()).toBe("ok")
  end)

  t.it("reports a session locked at start", function()
    local host, _, signals = start({})
    host.finish(1, { stdout = "(objectpath '" .. SESSION .. "',)\n" })
    host.finish(2, { stdout = "(<true>,)\n" })
    t.expect(signals).toEqual({ "lock" })
  end)

  t.it("falls back to the auto session", function()
    local host = start({})
    host.finish(1, { exitCode = 1, stderr = "NoSuchSession" })
    t.expect(host.commands[2].argv[#host.commands[2].argv]).toBe("auto")
  end)

  t.it("polls loginctl without gdbus", function()
    local host, monitor, signals = start({ commands = { loginctl = true } })
    t.expect(monitor.health()).toBe("poll")
    t.expect(host.commands[1].argv).toEqual({ "loginctl", "show-session", "2", "-p", "LockedHint" })
    host.finish(1, { stdout = "LockedHint=yes\n" })
    t.expect(signals).toEqual({ "lock" })
    monitor.tick()
    t.expect(#host.commands).toBe(1)
    host.clock.advance(15 * 1000)
    monitor.tick()
    host.finish(2, { stdout = "LockedHint=no\n" })
    t.expect(signals).toEqual({ "lock", "unlock" })
  end)

  t.it("is unavailable without gdbus nor a session id", function()
    local _, monitor = start({ commands = { loginctl = true }, env = {} })
    t.expect(monitor.health()).toBe("unavailable")
  end)
end)

t.finish()
