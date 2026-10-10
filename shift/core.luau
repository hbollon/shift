--!nonstrict
-- Shift core service: the single source of truth (spec §9.1). It owns the tracking
-- state, persists it, and publishes `shift.snapshot` for the UI entries, which send
-- their actions back as commands (lib/commands.luau). Every action becomes an event for
-- the reducer in lib/automation.luau; this file only wires the host to it.

local Automation = require("./lib/automation.luau")
local Commands = require("./lib/commands.luau")
local Host = require("./lib/host.luau")
local Model = require("./lib/model.luau")
local Store = require("./lib/store.luau")
local Time = require("./lib/time.luau")
local Types = require("./lib/types.luau")

local SNAPSHOT_KEY = "shift.snapshot"
local TICK_MS = 5000
local HEARTBEAT_S = 60

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

local function saveState()
  state.heartbeatS = nowS()
  lastSaveS = state.heartbeatS
  store:saveState(state)
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
    })
  )
end

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

local function apply(effects: { Types.Effect })
  for _, effect in effects do
    if effect.type == "ledger.addSession" then
      addSession(effect.date, effect.session)
    elseif effect.type == "state.save" then
      saveState()
    elseif effect.type == "publish" then
      publish()
    end
  end
end

local function dispatch(event: Types.Event): Types.Result
  local nextState, effects, result = Automation.reduce(state, event, { nowS = nowS(), settings = settings })
  state = nextState
  apply(effects)
  return result
end

-- Startup ----------------------------------------------------------------------

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

saveState()
publish()

-- Only explicit fields are forwarded: commands come from other entries' state writes.
Commands.receiver(host, function(cmd)
  return dispatch({ type = cmd.type })
end)

host.setUpdateInterval(TICK_MS)

-- Host callbacks ---------------------------------------------------------------

function update()
  local now = nowS()
  if now - lastSaveS >= HEARTBEAT_S then
    saveState()
  end
  -- Once a minute, so counters roll over to a new workday and week.
  if now // 60 ~= lastPublishMinute then
    publish()
  end
end

function onConfigChanged()
  settings = Model.readSettings(host.getConfig)
  publish()
end

local IPC_EVENTS = { checkin = true, checkout = true, toggle = true }

function onIpc(event, _payload)
  if not IPC_EVENTS[event] then
    host.log("unknown IPC event: " .. tostring(event))
    return
  end
  dispatch({ type = event })
end

-- Persist on reload, disable and shutdown; an open session stays open (E20, E21).
function onExit(_signal, _reason)
  saveState()
end
