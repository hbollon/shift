--!nonstrict
-- Shift core service: the single source of truth (spec §9.1). It owns the tracking
-- state, persists it, and publishes `shift.snapshot` for the UI entries, which send
-- their actions back as commands (lib/commands.luau). Every action, signal and tick
-- becomes an event for the reducer in lib/automation.luau; this file only wires the
-- host to it.

local Automation = require("./lib/automation.luau")
local Commands = require("./lib/commands.luau")
local Host = require("./lib/host.luau")
local Idle = require("./lib/signals/idle.luau")
local Logind = require("./lib/signals/logind.luau")
local Model = require("./lib/model.luau")
local Ring = require("./lib/ring.luau")
local Rules = require("./lib/rules.luau")
local Store = require("./lib/store.luau")
local Time = require("./lib/time.luau")
local Types = require("./lib/types.luau")

local SNAPSHOT_KEY = "shift.snapshot"
local TICK_MS = 5000
local HEARTBEAT_S = 60
-- A tick later than this means the clock jumped or the system slept (spec §6.3.2).
local GAP_S = 3 * TICK_MS // 1000 + 30
-- At startup, an older heartbeat means the service was not running (E1).
local STALE_HEARTBEAT_S = 2 * 60
-- A backward clock jump larger than this is logged (E7).
local BACKWARD_SLACK_S = 30

local host = Host.new()
local store = Store.new(host)
local settings = Model.readSettings(host.getConfig)
local state: Types.State = store:loadState()
local balance: Types.Balance? = store:loadBalance()
local lastSaveS = 0
local lastPublishMinute: number? = nil

local function nowS(): number
  return host.nowMs() // 1000
end

local lastTickS = nowS()

-- Automation window ---------------------------------------------------------------

-- Holidays and days off are not tracked yet: the `holidays` selector matches nothing.
local calendar = Rules.NO_CALENDAR
local rules: Rules.Compiled
local preview: { week: string, days: { string } }? = nil

local function compileRules()
  local window = settings.window
  rules = Rules.compile({
    workdays = settings.workdays,
    start = window.start,
    ["end"] = window["end"],
    excludeHolidays = window.excludeHolidays,
    extraRules = window.extraRules,
  })
  preview = nil
end

compileRules()

local windowProbe: Types.WindowProbe = {
  at = function(t)
    return Rules.at(rules, t, calendar)
  end,
  nextEdge = function(t)
    return Rules.nextEdge(rules, t, calendar)
  end,
}

-- Persistence and snapshot ------------------------------------------------------------

local function saveState()
  state.heartbeatS = nowS()
  lastSaveS = state.heartbeatS
  store:saveState(state)
end

local idle: Idle.IdleMonitor? = nil
local logind: Logind.LogindMonitor? = nil

local function automationInfo(now: number): Types.SnapshotAutomation
  local t = os.date("*t", now)
  local week = Time.weekStart(Time.dateKey(t.year, t.month, t.day))
  if not preview or preview.week ~= week then
    preview = { week = week, days = Rules.preview(rules, week, calendar) }
  end
  local hints = {}
  local hint = idle and idle.hint()
  if hint and not (state.hints and state.hints[hint]) then
    table.insert(hints, hint)
  end
  return {
    preset = settings.preset,
    idleMin = settings.idleTimeoutMin,
    window = { start = settings.window.start, ["end"] = settings.window["end"], extraRules = #settings.window.extraRules },
    backends = {
      idle = idle and idle.health() or "off",
      logind = logind and logind.health() or "off",
    },
    ruleErrors = rules.errors,
    preview = (preview :: any).days,
    hints = hints,
  }
end

local function publish()
  local now = nowS()
  lastPublishMinute = now // 60
  host.state.set(
    SNAPSHOT_KEY,
    Model.snapshot({
      state = state,
      nowS = now,
      settings = settings,
      meta = balance,
      dayOf = function(dateKey)
        return store:day(dateKey)
      end,
      automation = automationInfo(now),
    })
  )
end

-- Effects ------------------------------------------------------------------------------

local function addSession(date: string, session: Types.Session)
  local day = store:day(date, Model.newDay)
  local ok = Model.addSession(day, session)
  if ok then
    store:saveLedger(Time.year(date))
    return
  end
  -- Only reachable if the system clock went backwards during the session (E7).
  host.log(string.format("session %s on %s overlaps a recorded session, not saved", session.id, date))
  host.notifyError(host.tr("errors.overlap.title"), host.tr("errors.overlap.body"))
end

-- Applies `change` to the record of `date` and saves its ledger.
local function editDay(date: string, change: (day: Types.Day) -> ())
  local day = store:day(date, Model.newDay)
  change(day)
  store:saveLedger(Time.year(date))
end

local function apply(effects: { Types.Effect })
  for _, effect in effects do
    if effect.type == "ledger.addSession" then
      addSession(effect.date, effect.session)
    elseif effect.type == "ledger.removeSession" then
      editDay(effect.date, function(day)
        Model.removeSession(day, effect.id)
      end)
    elseif effect.type == "ledger.addAbsence" then
      editDay(effect.date, function(day)
        Model.addAbsence(day, effect.absence)
      end)
    elseif effect.type == "ledger.removeAbsence" then
      editDay(effect.date, function(day)
        Model.removeAbsence(day, effect.id)
      end)
    elseif effect.type == "ledger.setFlag" then
      editDay(effect.date, function(day)
        day.flags = day.flags or {}
        day.flags[effect.flag] = effect.value
      end)
    elseif effect.type == "state.save" then
      saveState()
    elseif effect.type == "publish" then
      publish()
    end
  end
end

local function dispatch(event: Types.Event): Types.Result
  local nextState, effects, result =
    Automation.reduce(state, event, { nowS = nowS(), settings = settings, window = windowProbe })
  state = nextState
  apply(effects)
  return result
end

-- Signals (spec §6.3.2) ---------------------------------------------------------------

local function onSignal(signal: string, atS: number)
  if signal == "resume" then
    lastTickS = nowS() -- the sleep is already an absence: no clock gap on top
  end
  local result = dispatch({ type = "signal", signal = signal, atS = atS })
  if not result.ok then
    host.log(string.format("signal %s: %s", signal, tostring(result.error)))
  end
end

local function startIdle()
  idle = Idle.start(host, {
    backend = settings.idleBackend,
    timeoutS = settings.idleTimeoutMin * 60,
    onSignal = onSignal,
  })
end

-- The manual preset ignores every signal: nothing is spawned then.
local function startSignals()
  if Model.usesSignals(settings) then
    startIdle()
    logind = Logind.start(host, onSignal)
  end
end

local function stopSignals()
  if idle then
    idle.stop()
    idle = nil
  end
  if logind then
    logind.stop()
    logind = nil
  end
end

-- Startup ------------------------------------------------------------------------------

if not balance then
  balance = {
    schema = Store.SCHEMA,
    trackingStart = Time.workdayOf(nowS(), settings.dayStartHour),
    initialBalanceMin = 0,
    adjustments = {},
  }
  store:saveBalance(balance)
end

-- A check-out writes the ledger before the state: if Noctalia stopped in between, the
-- open session is already recorded and must not stay open.
if state.open then
  local day = store:day(Time.workdayOf(state.open.startS, settings.dayStartHour))
  if day and Model.hasSession(day, state.open.id) then
    state.open = nil
  end
end

-- Rings cached for an older palette or older drawing code are never shown again.
Ring.prune(host)

do
  local heartbeat = state.heartbeatS
  local stale = state.open and heartbeat and nowS() - heartbeat > STALE_HEARTBEAT_S
  dispatch({ type = "start", startS = stale and heartbeat or nil })
end
startSignals()

-- Commands come from other entries' state writes: only the UI actions and their known
-- fields are forwarded (signals, ticks and the like are the service's own events).
local UI_COMMANDS = {
  checkin = true,
  checkout = true,
  undo = true,
  ["absence.resolve"] = true,
  ["suggestion.dismiss"] = true,
  ["hint.dismiss"] = true,
  ["onboarding.dismiss"] = true,
}
local COMMAND_FIELDS = { id = "string", keep = "boolean", kind = "string" }

Commands.receiver(host, function(cmd)
  if not UI_COMMANDS[cmd.type] then
    return { ok = false, error = "unknown_command" }
  end
  local event: Types.Event = { type = cmd.type }
  for field, kind in COMMAND_FIELDS do
    if type(cmd[field]) == kind then
      (event :: any)[field] = cmd[field]
    end
  end
  return dispatch(event)
end)

host.setUpdateInterval(TICK_MS)

-- Host callbacks ---------------------------------------------------------------------

function update()
  local now = nowS()
  if now < lastTickS - BACKWARD_SLACK_S then
    -- The clock went backwards (E7): no absence, the open session is kept.
    host.log(string.format("system clock went back by %d s", lastTickS - now))
  elseif state.open and now - lastTickS > GAP_S then
    dispatch({ type = "signal", signal = "gap", startS = lastTickS, endS = now })
  end
  lastTickS = now

  if idle then
    idle.tick()
  end
  if logind then
    logind.tick()
  end
  dispatch({ type = "tick" })

  if now - lastSaveS >= HEARTBEAT_S then
    saveState()
  end
  -- Once a minute, so counters roll over to a new workday and week.
  if now // 60 ~= lastPublishMinute then
    publish()
  end
end

function onConfigChanged()
  local old = settings
  settings = Model.readSettings(host.getConfig)
  compileRules()
  -- Restart only what the change concerns (spec §8).
  local restarted = false
  if Model.usesSignals(settings) ~= Model.usesSignals(old) then
    stopSignals()
    startSignals()
    restarted = true
  elseif idle and (settings.idleBackend ~= old.idleBackend or settings.idleTimeoutMin ~= old.idleTimeoutMin) then
    idle.stop()
    startIdle()
    restarted = true
  end
  dispatch({ type = "config", restarted = restarted })
  publish()
end

local IPC_EVENTS = { checkin = true, checkout = true, toggle = true, undo = true }
local IPC_SIGNALS = { idle = true, active = true, lock = true, unlock = true, sleep = true, resume = true }

local function trim(payload: any): string
  return type(payload) == "string" and (string.match(payload, "^%s*(.-)%s*$") :: string) or ""
end

function onIpc(event, payload)
  local arg = trim(payload)
  local result: Types.Result
  if IPC_EVENTS[event] then
    result = dispatch({ type = event })
  elseif event == "resolve" and (arg == "keep" or arg == "remove") then
    local oldest = state.pending and state.pending[1]
    if not oldest then
      result = { ok = false, error = "nothing_pending" }
    else
      result = dispatch({ type = "absence.resolve", id = oldest.id, keep = arg == "keep" })
    end
  elseif event == "signal" and IPC_SIGNALS[arg] then
    -- External integrations (idle_backend = external, spec §11).
    onSignal(arg, nowS())
    return
  else
    host.log(string.format("unknown IPC event: %s %s", tostring(event), arg))
    return
  end
  if not result.ok then
    host.log(string.format("IPC %s: %s", event, tostring(result.error)))
  end
end

-- Persist on reload, disable and shutdown; an open session stays open (E20, E21).
function onExit(_signal, _reason)
  saveState()
end
