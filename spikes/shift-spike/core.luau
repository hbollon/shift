--!nonstrict
-- Spike service: S1 (swayidle via runStream), S2 (logind via gdbus/busctl/loginctl),
-- S4 (string_list read-back), S5 (state channel throughput and watch semantics).
--
-- Drive it with: noctalia msg plugin hbollon/shift-spike:core all <event> [payload]

local log = require("./lib/log.luau")
log.init("core")

-- ---------------------------------------------------------------------------
-- S1: swayidle
-- ---------------------------------------------------------------------------

local function startIdle(variant)
  if not noctalia.commandExists("swayidle") then
    log.write("S1 swayidle not on PATH")
    return
  end
  local timeout = noctalia.getConfig("idle_timeout_s") or 5
  local cmd
  if variant == "exec" then
    cmd = string.format("exec swayidle -w timeout %d 'echo idle' resume 'echo active'", timeout)
  else
    cmd = string.format("swayidle -w timeout %d 'echo idle' resume 'echo active'", timeout)
  end
  local ok = noctalia.runStream(cmd, function(line)
    log.write("S1 swayidle> " .. line)
  end)
  log.write(string.format("S1 runStream(%s) accepted=%s timeout=%ds", variant or "plain", tostring(ok), timeout))
end

-- ---------------------------------------------------------------------------
-- S2: logind
-- ---------------------------------------------------------------------------

local sessionPath = nil

local function resolveSession()
  local sid = noctalia.getenv("XDG_SESSION_ID")
  log.write("S2 XDG_SESSION_ID=" .. tostring(sid))
  local function call(label, argv)
    noctalia.runAsync(argv, function(r)
      log.write(string.format("S2 %s exit=%d out=%s err=%s", label, r.exitCode, noctalia.string.trim(r.stdout), noctalia.string.trim(r.stderr)))
      local p = string.match(r.stdout, "objectpath '([^']+)'")
      if p and not sessionPath then
        sessionPath = p
        log.write("S2 session path resolved: " .. p)
      end
    end)
  end
  if sid then
    call("GetSession($XDG_SESSION_ID)", { "gdbus", "call", "--system", "--dest", "org.freedesktop.login1",
      "--object-path", "/org/freedesktop/login1", "--method", "org.freedesktop.login1.Manager.GetSession", sid })
  end
  call("GetSession(auto)", { "gdbus", "call", "--system", "--dest", "org.freedesktop.login1",
    "--object-path", "/org/freedesktop/login1", "--method", "org.freedesktop.login1.Manager.GetSession", "auto" })
  -- The shell's parent is the Noctalia process itself.
  noctalia.runAsync("gdbus call --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 "
    .. "--method org.freedesktop.login1.Manager.GetSessionByPID $PPID", function(r)
    log.write(string.format("S2 GetSessionByPID($PPID) exit=%d out=%s err=%s", r.exitCode, noctalia.string.trim(r.stdout), noctalia.string.trim(r.stderr)))
  end)
end

local function startMonitor(variant)
  local cmds = {
    gdbus = "gdbus monitor --system --dest org.freedesktop.login1",
    stdbuf = "stdbuf -oL gdbus monitor --system --dest org.freedesktop.login1",
    busctl = "busctl monitor --system --json=short org.freedesktop.login1",
  }
  local cmd = cmds[variant]
  if not cmd then
    log.write("S2 unknown monitor variant " .. tostring(variant))
    return
  end
  local ok = noctalia.runStream(cmd, function(line)
    if #line > 400 then
      line = string.sub(line, 1, 400) .. "…"
    end
    log.write("S2 " .. variant .. "> " .. line)
  end)
  log.write(string.format("S2 runStream(%s) accepted=%s", variant, tostring(ok)))
end

local function pollLocked()
  local sid = noctalia.getenv("XDG_SESSION_ID") or "auto"
  local t0 = noctalia.nowMs()
  noctalia.runAsync({ "loginctl", "show-session", sid, "-p", "LockedHint", "-p", "IdleHint" }, function(r)
    log.write(string.format("S2 loginctl poll (%d ms) exit=%d %s", noctalia.nowMs() - t0, r.exitCode, string.gsub(r.stdout, "\n", " ")))
  end)
end

-- ---------------------------------------------------------------------------
-- S5: state channel
-- ---------------------------------------------------------------------------

local function snapshot(i)
  -- Shape and size of the snapshot specified in §9.3.
  return {
    v = 1,
    seq = i,
    status = "working",
    since = 1791529020,
    today = { date = "2026-10-09", workedClosedMs = 12840000 + i, openStartMs = 1791547320000, removedInOpenMs = 0,
      targetMs = 25200000, isWorkday = true },
    week = { workedMs = 101400000, targetMs = 126000000 },
    balance = { settledMs = 16500000, toReview = { "2026-10-02" } },
    pending = {
      { id = "a_8f2c", startS = 1791540720, endS = 1791543240, signal = "lock" },
      { id = "a_8f2d", startS = 1791550720, endS = 1791553240, signal = "idle" },
    },
    suggestion = nil,
    undo = { label = "Check out at 17:02", atS = 1791558120 },
    automation = { preset = "assisted", idleMin = 5, backends = { idle = "ok", logind = "ok", holidays = "ok" },
      ruleErrors = { { index = 3, text = "- mon-fry", reason = "unknown day 'fry'" } },
      windowSummary = "Mon–Fri 08:00–19:00" },
    flags = { firstRun = false, needsReview = { "2026-10-07" } },
  }
end

local function bench(n)
  local encoded = noctalia.json.encode(snapshot(0))
  log.write(string.format("S5 snapshot json size=%d bytes", #encoded))
  noctalia.state.set("spike.bench.n", n)
  local t0 = noctalia.nowMs()
  for i = 1, n do
    noctalia.state.set("spike.snapshot", snapshot(i))
  end
  local dt = noctalia.nowMs() - t0
  log.write(string.format("S5 published %d snapshots in %d ms (%.3f ms/set), sentAt=%d", n, dt, dt / n, t0))
  noctalia.state.set("spike.bench.sentAt", t0)
end

local function sameValueTest()
  log.write("S5 same-value test: setting identical table x2, identical string x2, then a new seq table")
  noctalia.state.set("spike.same.tbl", { a = 1, b = { 2, 3 } })
  noctalia.state.set("spike.same.tbl", { a = 1, b = { 2, 3 } })
  noctalia.state.set("spike.same.str", "x")
  noctalia.state.set("spike.same.str", "x")
  noctalia.state.set("spike.same.tbl", { a = 1, b = { 2, 3 }, seq = 2 })
end

-- Command channel: UI -> service, with seq so identical commands still fire.
noctalia.state.watch("spike.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  log.write(string.format("S5 cmd seq=%s type=%s latency=%d ms", tostring(cmd.seq), tostring(cmd.type), noctalia.nowMs() - (cmd.atMs or 0)))
end)

-- ---------------------------------------------------------------------------
-- Lifecycle, ticks, IPC
-- ---------------------------------------------------------------------------

local lastTickMs = noctalia.nowMs()
noctalia.setUpdateInterval(5000)

function update()
  local now = noctalia.nowMs()
  local gap = now - lastTickMs
  if gap > 3 * 5000 + 30000 then
    log.write(string.format("gap detector: %d s since last tick (suspend?)", gap // 1000))
  end
  lastTickMs = now
end

function onConfigChanged()
  local rules = noctalia.getConfig("schedule_rules")
  local parts = {}
  if type(rules) == "table" then
    for i, r in ipairs(rules) do
      table.insert(parts, string.format("[%d]=%q", i, r))
    end
  end
  log.write(string.format("S4 onConfigChanged automation=%s work_week=%s rules(type=%s,n=%d): %s",
    tostring(noctalia.getConfig("automation")), tostring(noctalia.getConfig("work_week")), type(rules),
    type(rules) == "table" and #rules or -1, table.concat(parts, " ")))
end

function onIpc(event, payload)
  log.write(string.format("ipc %s %s", tostring(event), tostring(payload)))
  if event == "idle" then
    startIdle(payload)
  elseif event == "session" then
    resolveSession()
  elseif event == "monitor" then
    startMonitor(payload or "gdbus")
  elseif event == "poll" then
    pollLocked()
  elseif event == "bench" then
    bench(tonumber(payload) or 100)
  elseif event == "same" then
    sameValueTest()
  elseif event == "config" then
    onConfigChanged()
  elseif event == "settings" then
    noctalia.openSettings()
  end
end

function onExit(signal, reason)
  log.write(string.format("onExit signal=%s reason=%s", tostring(signal), tostring(reason)))
end

onConfigChanged()
