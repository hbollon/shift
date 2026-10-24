--!nonstrict
local t = require("./lib/testing.luau")
local Automation = require("../shift/lib/automation.luau")
local Model = require("../shift/lib/model.luau")
local Rules = require("../shift/lib/rules.luau")
local Time = require("../shift/lib/time.luau")

local SETTINGS = Model.readSettings(function() end)
local NINE = Time.localToEpoch(2026, 10, 9, 9, 0)

local function reduce(state, eventType, nowS, id)
  return Automation.reduce(state, { type = eventType, id = id }, { nowS = nowS, settings = SETTINGS })
end

local function types(effects)
  local out = {}
  for _, effect in effects do
    table.insert(out, effect.type)
  end
  return out
end

t.describe("automation.manual", function()
  t.it("opens a session on check-in", function()
    local state: any = { heartbeatS = 1 }
    local next, effects, result = reduce(state, "checkin", NINE)
    t.expect(next.open).toEqual({ id = Model.sessionId(NINE), startS = NINE, origin = "manual" })
    t.expect(next.heartbeatS).toBe(1)
    t.expect(next.firstRunDismissed).toBe(true)
    t.expect(state.open).toBeNil() -- the input state is not mutated
    t.expect(types(effects)).toEqual({ "state.save", "publish" })
    t.expect(result).toEqual({ ok = true, changed = true })
  end)

  t.it("records the session in its workday on check-out", function()
    local working = reduce({}, "checkin", NINE)
    local next, effects, result = reduce(working, "checkout", NINE + 3600)
    t.expect(next.open).toBeNil()
    t.expect(working.open).toBeTruthy() -- the input state is not mutated
    t.expect(types(effects)).toEqual({ "ledger.addSession", "state.save", "publish" })
    t.expect(effects[1].date).toBe("2026-10-09")
    t.expect(effects[1].session).toEqual({ id = working.open.id, startS = NINE, endS = NINE + 3600, origin = "manual" })
    t.expect(result.changed).toBe(true)
  end)

  t.it("attributes a session past midnight to the workday it started on", function()
    local late = Time.localToEpoch(2026, 10, 9, 23, 0)
    local working = reduce({}, "checkin", late)
    local _, effects = reduce(working, "checkout", late + 3 * 3600)
    t.expect(effects[1].date).toBe("2026-10-09")
  end)

  t.it("drops a zero-length session", function()
    local working = reduce({}, "checkin", NINE)
    local next, effects = reduce(working, "checkout", NINE)
    t.expect(next.open).toBeNil()
    t.expect(types(effects)).toEqual({ "state.save", "publish" })
  end)

  t.it("treats repeated commands as no-ops", function()
    local working = reduce({}, "checkin", NINE)
    local again, effects, result = reduce(working, "checkin", NINE + 60)
    t.expect(again).toBe(working)
    t.expect(#effects).toBe(0)
    t.expect(result).toEqual({ ok = true, changed = false })
    local _, offEffects, offResult = reduce({}, "checkout", NINE)
    t.expect(#offEffects).toBe(0)
    t.expect(offResult.changed).toBe(false)
  end)

  t.it("toggles between working and off", function()
    local working = reduce({}, "toggle", NINE)
    t.expect(working.open.startS).toBe(NINE)
    local off = reduce(working, "toggle", NINE + 60)
    t.expect(off.open).toBeNil()
  end)

  t.it("rejects unknown commands", function()
    local state: any = {}
    local next, effects, result = reduce(state, "explode", NINE)
    t.expect(next).toBe(state)
    t.expect(#effects).toBe(0)
    t.expect(result).toEqual({ ok = false, error = "unknown_command" })
  end)
end)

t.describe("automation.undo", function()
  t.it("records every action on the undo stack", function()
    local working = reduce({}, "checkin", NINE)
    local off = reduce(working, "checkout", NINE + 60)
    t.expect(#off.undo).toBe(2)
    t.expect(off.undo[1].id).toBe("checkin:" .. working.open.id)
    t.expect(off.undo[2]).toEqual({
      id = "checkout:" .. working.open.id,
      action = "checkout",
      atS = NINE + 60,
      session = { id = working.open.id, startS = NINE, endS = NINE + 60, origin = "manual" },
      date = "2026-10-09",
      recorded = true,
    })
  end)

  t.it("undoes a check-in", function()
    local working = reduce({}, "checkin", NINE)
    local next, effects, result = reduce(working, "undo", NINE + 30)
    t.expect(next.open).toBeNil()
    t.expect(#next.undo).toBe(0)
    t.expect(types(effects)).toEqual({ "state.save", "publish" })
    t.expect(result.changed).toBe(true)
  end)

  t.it("undoes a check-out by reopening the session", function()
    local working = reduce({}, "checkin", NINE)
    local off = reduce(working, "checkout", NINE + 3600)
    local next, effects = reduce(off, "undo", NINE + 3700)
    t.expect(next.open).toEqual(working.open)
    t.expect(types(effects)).toEqual({ "ledger.removeSession", "state.save", "publish" })
    t.expect(effects[1].date).toBe("2026-10-09")
    t.expect(effects[1].id).toBe(working.open.id)
  end)

  t.it("does not touch the ledger when the session was not recorded", function()
    local working = reduce({}, "checkin", NINE)
    local off = reduce(working, "checkout", NINE)
    local _, effects = reduce(off, "undo", NINE + 1)
    t.expect(types(effects)).toEqual({ "state.save", "publish" })
  end)

  t.it("chains undos while the entries are recent", function()
    local working = reduce({}, "checkin", NINE)
    local off = reduce(working, "checkout", NINE + 60)
    local reopened = reduce(off, "undo", NINE + 120)
    local before = reduce(reopened, "undo", NINE + 180)
    t.expect(before.open).toBeNil()
    t.expect(#before.undo).toBe(0)
  end)

  t.it("refuses actions older than the undo window", function()
    local working = reduce({}, "checkin", NINE)
    local next, effects, result = reduce(working, "undo", NINE + Model.UNDO_WINDOW_S)
    t.expect(next).toBe(working)
    t.expect(#effects).toBe(0)
    t.expect(result).toEqual({ ok = false, error = "nothing_to_undo" })
  end)

  t.it("ignores an undo aimed at another action", function()
    local working = reduce({}, "checkin", NINE)
    local off = reduce(working, "checkout", NINE + 60)
    local targetId = off.undo[2].id
    local reopened = reduce(off, "undo", NINE + 70, targetId)
    -- The same command delivered again now targets an entry that is no longer on top.
    local again, effects, result = reduce(reopened, "undo", NINE + 71, targetId)
    t.expect(again).toBe(reopened)
    t.expect(#effects).toBe(0)
    t.expect(result).toEqual({ ok = true, changed = false })
    t.expect(again.open).toBeTruthy()
  end)

  t.it("keeps the twenty most recent actions", function()
    local state: any = {}
    for i = 1, 15 do
      state = reduce(state, "checkin", NINE + i * 10)
      state = reduce(state, "checkout", NINE + i * 10 + 5)
    end
    t.expect(#state.undo).toBe(Model.UNDO_DEPTH)
    t.expect(state.undo[Model.UNDO_DEPTH].atS).toBe(NINE + 155)
  end)
end)

t.describe("automation.onboarding", function()
  t.it("dismisses the first-run card once", function()
    local next, effects = reduce({}, "onboarding.dismiss", NINE)
    t.expect(next.firstRunDismissed).toBe(true)
    t.expect(types(effects)).toEqual({ "state.save", "publish" })
    local again, againEffects = reduce(next, "onboarding.dismiss", NINE)
    t.expect(again).toBe(next)
    t.expect(#againEffects).toBe(0)
  end)
end)

-- Scenarios -------------------------------------------------------------------------
-- A scenario feeds events to the reducer with the window of its settings, keeps every
-- effect and applies the session effects to a ledger of its own. 2026-10-09 is a Friday;
-- the default window is 08:00–19:00 on Mon–Fri.

local FRI, SAT = "2026-10-09", "2026-10-10"

local function at(day, hour, min, sec)
  local year, month, d = Time.parseDate(day)
  return Time.localToEpoch(year, month, d, hour, min or 0) + (sec or 0)
end

local function scenario(config, state)
  local settings = Model.readSettings(function(key)
    return (config or {})[key]
  end)
  local compiled = Rules.compile({
    workdays = settings.workdays,
    start = settings.window.start,
    ["end"] = settings.window["end"],
    excludeHolidays = settings.window.excludeHolidays,
    extraRules = settings.window.extraRules,
  })
  local window = {
    at = function(epochS)
      return Rules.at(compiled, epochS, Rules.NO_CALENDAR)
    end,
    nextEdge = function(epochS)
      return Rules.nextEdge(compiled, epochS, Rules.NO_CALENDAR)
    end,
  }
  local sc = {
    state = state or { schema = 1 },
    effects = {},
    days = {},
    balance = { schema = 1, trackingStart = "2026-10-01", initialBalanceMin = 0, adjustments = {} },
  }
  local function dayOf(date)
    return sc.days[date]
  end
  function sc.send(event, nowS)
    local next, effects, result = Automation.reduce(
      sc.state,
      event,
      { nowS = nowS, settings = settings, window = window, dayOf = dayOf, balance = sc.balance }
    )
    sc.state = next
    for _, effect in effects do
      table.insert(sc.effects, effect)
      if effect.type == "ledger.addSession" then
        sc.days[effect.date] = sc.days[effect.date] or Model.newDay()
        t.expect((Model.addSession(sc.days[effect.date], effect.session))).toBe(true)
      elseif effect.type == "ledger.removeSession" then
        t.expect(Model.removeSession(sc.days[effect.date], effect.id)).toBe(true)
      elseif effect.type == "ledger.setFlag" then
        sc.days[effect.date] = sc.days[effect.date] or Model.newDay()
        sc.days[effect.date].flags[effect.flag] = effect.value
      elseif effect.type == "ledger.setDay" then
        sc.days[effect.date] = effect.day
      elseif effect.type == "balance.save" then
        sc.balance = effect.balance
      end
    end
    return result
  end
  -- Recorded sessions of a day as { startS, endS } pairs, in order.
  function sc.sessions(date)
    local list = {}
    for _, session in sc.days[date] and sc.days[date].sessions or {} do
      table.insert(list, { session.startS, session.endS })
    end
    return list
  end
  function sc.signal(signal, nowS)
    return sc.send({ type = "signal", signal = signal, atS = nowS }, nowS)
  end
  -- Ticks every 5 s from `fromS` to `toS` included.
  function sc.ticks(fromS, toS)
    for nowS = fromS, toS, 5 do
      sc.send({ type = "tick" }, nowS)
    end
  end
  function sc.of(effectType)
    local list = {}
    for _, effect in sc.effects do
      if effect.type == effectType then
        table.insert(list, effect)
      end
    end
    return list
  end
  return sc
end

t.describe("automation.checkin", function()
  t.it("suggests a check-in on activity inside the window (assisted)", function()
    local sc = scenario()
    sc.send({ type = "start" }, at(FRI, 7, 30))
    t.expect(sc.state.suggestion).toBeNil() -- before the window
    sc.signal("active", at(FRI, 8, 14))
    t.expect(sc.state.suggestion).toEqual({ kind = "checkin", untilS = at(FRI, 19) })
    t.expect(sc.state.open).toBeNil()
  end)

  t.it("holds a dismissed suggestion until the segment ends", function()
    local sc = scenario({ extra_rules = { "- * 12:00-13:30" } })
    sc.signal("active", at(FRI, 9))
    sc.send({ type = "suggestion.dismiss", kind = "checkin" }, at(FRI, 9, 1))
    t.expect(sc.state.suggestion).toBeNil()
    sc.signal("active", at(FRI, 11))
    t.expect(sc.state.suggestion).toBeNil()
    sc.signal("active", at(FRI, 13, 40)) -- after lunch, a new segment
    t.expect(sc.state.suggestion.kind).toBe("checkin")
  end)

  t.it("drops a check-in suggestion when the window closes", function()
    local sc = scenario()
    sc.signal("active", at(FRI, 18, 50))
    sc.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 5))
    t.expect(sc.state.suggestion).toBeNil()
  end)

  t.it("checks in at service start inside the window (automatic)", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "start" }, at(FRI, 8, 30))
    t.expect(sc.state.open).toEqual({ id = Model.sessionId(at(FRI, 8, 30)), startS = at(FRI, 8, 30), origin = "auto" })
    t.expect(sc.state.undo[1].action).toBe("checkin")
  end)

  t.it("checks in when the window opens while the user is active", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "start" }, at(FRI, 7, 50))
    sc.ticks(at(FRI, 7, 59, 50), at(FRI, 8, 0, 5))
    t.expect(sc.state.open.startS).toBe(at(FRI, 8))
  end)

  t.it("does not check in when the window opens while the user is away", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "start" }, at(FRI, 7, 50))
    sc.signal("lock", at(FRI, 7, 55))
    sc.ticks(at(FRI, 7, 59, 50), at(FRI, 8, 0, 5))
    t.expect(sc.state.open).toBeNil()
    sc.signal("unlock", at(FRI, 8, 20))
    t.expect(sc.state.open.startS).toBe(at(FRI, 8, 20))
  end)

  t.it("holds automatic check-in after a manual check-out inside a segment (E8)", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "start" }, at(FRI, 8, 30))
    sc.send({ type = "checkout" }, at(FRI, 12))
    t.expect(sc.state.overrides.suppressCheckinUntilS).toBe(at(FRI, 19))
    sc.signal("active", at(FRI, 15))
    t.expect(sc.state.open).toBeNil()
  end)
end)

t.describe("automation.checkout", function()
  t.it("checks out at the window end (automatic)", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "start" }, at(FRI, 8, 30))
    sc.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 5))
    t.expect(sc.state.open).toBeNil()
    local added = sc.of("ledger.addSession")
    t.expect(added[1].session.endS).toBe(at(FRI, 19))
    t.expect(sc.state.overrides.suppressCheckinUntilS).toBeNil()
  end)

  t.it("suggests a check-out at the window end (assisted)", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 5))
    t.expect(sc.state.open).toBeTruthy()
    t.expect(sc.state.suggestion).toEqual({ kind = "checkout", untilS = at("2026-10-12", 8) })
    sc.send({ type = "checkout" }, at(FRI, 19, 5))
    t.expect(sc.state.suggestion).toBeNil()
  end)

  t.it("never closes a session started manually outside the window (E9)", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "checkin" }, at(SAT, 10))
    t.expect(sc.state.overrides.manualSession).toBe(true)
    local early = scenario({ automation = "automatic" })
    early.send({ type = "checkin" }, at(FRI, 7))
    early.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 5))
    t.expect(early.state.open.startS).toBe(at(FRI, 7))
    t.expect(early.state.suggestion).toBeNil()
  end)
end)

t.describe("automation.notifications", function()
  t.it("notifies a check-in suggestion once per window segment", function()
    local sc = scenario({ extra_rules = { "- * 12:00-13:30" } })
    sc.signal("active", at(FRI, 9))
    sc.signal("active", at(FRI, 11))
    t.expect(sc.of("notify")).toEqual({ { type = "notify", kind = "checkin" } })
    sc.send({ type = "suggestion.dismiss", kind = "checkin" }, at(FRI, 11, 1))
    sc.signal("active", at(FRI, 12, 30)) -- lunch break, outside the window
    sc.signal("active", at(FRI, 13, 40)) -- a new segment
    t.expect(#sc.of("notify")).toBe(2)
  end)

  t.it("notifies a check-out suggestion at the window end", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 30))
    t.expect(sc.of("notify")).toEqual({ { type = "notify", kind = "checkout" } })
  end)

  t.it("notifies an absence to review with its length", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 12))
    sc.signal("unlock", at(FRI, 12, 42))
    t.expect(sc.of("notify")).toEqual({ { type = "notify", kind = "absence", ms = 42 * 60000 } })
    -- Undoing its removal brings it back to review without a new notification.
    sc.send({ type = "absence.resolve", id = sc.state.pending[1].id, keep = false }, at(FRI, 13))
    sc.send({ type = "undo" }, at(FRI, 13, 1))
    t.expect(#sc.state.pending).toBe(1)
    t.expect(#sc.of("notify")).toBe(1)
  end)

  t.it("does not notify what happens on its own, nor when turned off", function()
    local auto = scenario({ automation = "automatic", idle_action = "deduct" })
    auto.signal("active", at(FRI, 9))
    auto.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 30))
    t.expect(auto.of("notify")).toEqual({})
    local custom = scenario({ automation = "custom", idle_action = "deduct", lock_action = "deduct" })
    custom.send({ type = "checkin" }, at(FRI, 9))
    custom.signal("lock", at(FRI, 12))
    custom.signal("unlock", at(FRI, 13))
    t.expect(custom.of("notify")).toEqual({})
    local quiet = scenario({ notify_suggestions = false, notify_pending_absence = false })
    quiet.signal("active", at(FRI, 9))
    quiet.send({ type = "checkin" }, at(FRI, 9, 5))
    quiet.signal("lock", at(FRI, 12))
    quiet.signal("unlock", at(FRI, 13))
    quiet.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 30))
    t.expect(#quiet.state.pending).toBe(1)
    t.expect(quiet.state.suggestion.kind).toBe("checkout")
    t.expect(quiet.of("notify")).toEqual({})
  end)
end)

t.describe("automation.absences", function()
  t.it("records a long absence as pending and cuts it out of the open session when removed", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    local first = sc.state.open
    sc.signal("lock", at(FRI, 12))
    t.expect(Model.status(sc.state, Model.readSettings(function() end))).toBe("away")
    sc.signal("unlock", at(FRI, 13))
    local id = Model.absenceId(at(FRI, 12))
    t.expect(sc.state.pending).toEqual({
      { id = id, date = FRI, startS = at(FRI, 12), endS = at(FRI, 13), signals = { "lock" } },
    })
    t.expect(sc.state.absence).toBeNil()

    -- Checked out at the absence start, back in on return.
    sc.send({ type = "absence.resolve", id = id, keep = false }, at(FRI, 14))
    t.expect(sc.state.pending).toBeNil()
    t.expect(sc.sessions(FRI)).toEqual({ { at(FRI, 9), at(FRI, 12) } })
    t.expect(sc.days[FRI].sessions[1].id).toBe(first.id)
    t.expect(sc.state.open).toEqual({ id = Model.sessionId(at(FRI, 13)), startS = at(FRI, 13), origin = "manual" })
    -- Delivered twice: nothing more happens.
    local again = sc.send({ type = "absence.resolve", id = id, keep = false }, at(FRI, 14))
    t.expect(again.changed).toBe(false)

    sc.send({ type = "undo", id = "resolve:" .. id }, at(FRI, 14, 1))
    t.expect(sc.sessions(FRI)).toEqual({})
    t.expect(sc.state.open).toEqual(first)
    t.expect(sc.state.pending[1].id).toBe(id)
  end)

  t.it("leaves the session whole when an absence is kept", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    local open = sc.state.open
    sc.signal("lock", at(FRI, 12))
    sc.signal("unlock", at(FRI, 13))
    local id = sc.state.pending[1].id
    local before = #sc.effects
    sc.send({ type = "absence.resolve", id = id, keep = true }, at(FRI, 14))
    t.expect(sc.state.pending).toBeNil()
    t.expect(sc.state.open).toBe(open)
    t.expect(types({ table.unpack(sc.effects, before + 1) })).toEqual({ "state.save", "publish" })
    sc.send({ type = "undo", id = "resolve:" .. id }, at(FRI, 14, 1))
    t.expect(sc.state.pending[1].id).toBe(id)
  end)

  t.it("cuts a removed absence out of a closed session", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 12))
    sc.signal("unlock", at(FRI, 13))
    sc.send({ type = "checkout" }, at(FRI, 17))
    sc.send({ type = "absence.resolve", id = sc.state.pending[1].id, keep = false }, at(FRI, 17, 5))
    t.expect(sc.sessions(FRI)).toEqual({ { at(FRI, 9), at(FRI, 12) }, { at(FRI, 13), at(FRI, 17) } })
    t.expect(sc.days[FRI].sessions[2].id).toBe(Model.sessionId(at(FRI, 13)))
    t.expect(sc.state.open).toBeNil()

    sc.send({ type = "undo" }, at(FRI, 17, 6))
    t.expect(sc.sessions(FRI)).toEqual({ { at(FRI, 9), at(FRI, 17) } })
    t.expect(#sc.state.pending).toBe(1)
  end)

  t.it("moves the session start when the absence opens it", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.send({ type = "start", startS = at(FRI, 9) }, at(FRI, 10))
    sc.send({ type = "absence.resolve", id = sc.state.pending[1].id, keep = false }, at(FRI, 10, 1))
    t.expect(sc.sessions(FRI)).toEqual({})
    t.expect(sc.state.open.startS).toBe(at(FRI, 10))
  end)

  t.it("undoes a removal only while the session that went on is open", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 12))
    sc.signal("unlock", at(FRI, 13))
    sc.send({ type = "absence.resolve", id = sc.state.pending[1].id, keep = false }, at(FRI, 13, 1))
    sc.send({ type = "checkout" }, at(FRI, 13, 2))
    sc.send({ type = "undo" }, at(FRI, 13, 3)) -- reopens the afternoon session
    sc.send({ type = "undo" }, at(FRI, 13, 4)) -- joins it back to the morning
    t.expect(sc.sessions(FRI)).toEqual({})
    t.expect(sc.state.open.startS).toBe(at(FRI, 9))
  end)

  t.it("counts short absences as work (E11)", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("idle", at(FRI, 10, 10)) -- inactive since 10:05
    sc.signal("active", at(FRI, 10, 19))
    t.expect(sc.state.pending).toBeNil()
    t.expect(sc.state.open.startS).toBe(at(FRI, 9))
  end)

  t.it("dates idle absences back by the idle timeout", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.ticks(at(FRI, 10, 4), at(FRI, 10, 4))
    t.expect(sc.state.lastActivityS).toBe(at(FRI, 10, 4))
    sc.signal("idle", at(FRI, 10, 5))
    t.expect(sc.state.absence).toEqual({ startS = at(FRI, 10), signals = { "idle" } })
    t.expect(sc.state.lastActivityS).toBe(at(FRI, 10))
  end)

  t.it("merges idle, lock and sleep and follows the strongest (E10)", function()
    local sc = scenario({ automation = "custom", idle_action = "ignore", lock_action = "ask", sleep_action = "deduct" })
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("idle", at(FRI, 12, 5))
    sc.signal("lock", at(FRI, 12, 10))
    sc.signal("sleep", at(FRI, 12, 20))
    sc.signal("resume", at(FRI, 13, 30))
    t.expect(sc.state.absence).toBeTruthy() -- still locked
    sc.signal("active", at(FRI, 13, 31)) -- on the lock screen: not activity
    t.expect(sc.state.absence).toBeTruthy()
    sc.signal("unlock", at(FRI, 13, 32))
    -- Removed without asking (deduct), still undoable back to pending.
    t.expect(sc.sessions(FRI)).toEqual({ { at(FRI, 9), at(FRI, 12) } })
    t.expect(sc.state.open.startS).toBe(at(FRI, 13, 32))
    t.expect(sc.state.undo[#sc.state.undo].action).toBe("resolve")
    sc.send({ type = "undo" }, at(FRI, 13, 33))
    t.expect(sc.state.open.startS).toBe(at(FRI, 9))
    t.expect(sc.state.pending[1].signals).toEqual({ "idle", "lock", "sleep" })
  end)

  t.it("ignores absences when the action is ignore", function()
    local sc = scenario({ automation = "manual" })
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 10))
    t.expect(Model.status(sc.state, Model.readSettings(function(key)
      return key == "automation" and "manual" or nil
    end))).toBe("working")
    sc.signal("unlock", at(FRI, 12))
    t.expect(sc.state.pending).toBeNil()
  end)

  t.it("checks out at the absence start once the threshold is crossed", function()
    local sc = scenario({ automation = "custom", auto_checkin = "auto", idle_action = "checkout" })
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("idle", at(FRI, 10, 5)) -- since 10:00
    sc.ticks(at(FRI, 10, 14, 55), at(FRI, 10, 15, 0))
    t.expect(sc.state.open).toBeNil()
    t.expect(sc.of("ledger.addSession")[1].session.endS).toBe(at(FRI, 10))
    sc.signal("active", at(FRI, 10, 40))
    t.expect(sc.state.open.startS).toBe(at(FRI, 10, 40)) -- back: automatic check-in
  end)

  t.it("closes the absence at check-out when checking out while away", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 17))
    sc.send({ type = "checkout" }, at(FRI, 17, 30))
    t.expect(sc.state.pending[1].endS).toBe(at(FRI, 17, 30))
    t.expect(sc.of("ledger.addSession")[1].session.endS).toBe(at(FRI, 17, 30))
  end)

  t.it("trims a pending absence to the session end", function()
    local sc = scenario({ automation = "automatic" })
    sc.send({ type = "start" }, at(FRI, 8, 30))
    sc.signal("lock", at(FRI, 18, 30))
    sc.ticks(at(FRI, 18, 59, 55), at(FRI, 19, 0, 5))
    t.expect(sc.state.open).toBeNil()
    t.expect(sc.state.pending[1].startS).toBe(at(FRI, 18, 30))
    t.expect(sc.state.pending[1].endS).toBe(at(FRI, 19))
  end)

  t.it("records the time the service was not running (E1)", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.send({ type = "start", startS = at(FRI, 10) }, at(FRI, 10, 45))
    t.expect(sc.state.pending[1].signals).toEqual({ "gap" })
    t.expect(sc.state.pending[1].startS).toBe(at(FRI, 10))
    t.expect(sc.state.pending[1].endS).toBe(at(FRI, 10, 45))
  end)

  t.it("merges a clock gap into the sleep it belongs to", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("sleep", at(FRI, 12))
    sc.send({ type = "signal", signal = "gap", startS = at(FRI, 11, 59, 58), endS = at(FRI, 13) }, at(FRI, 13))
    t.expect(sc.state.absence).toEqual({ startS = at(FRI, 11, 59, 58), signals = { "sleep", "gap" } })
    sc.signal("resume", at(FRI, 13))
    t.expect(#sc.state.pending).toBe(1)
  end)

  t.it("forgets signals when their sources restart", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 10))
    sc.send({ type = "config", restarted = true }, at(FRI, 10, 30))
    t.expect(sc.state.presence).toEqual({})
    t.expect(sc.state.pending[1].endS).toBe(at(FRI, 10, 30))
  end)
end)

t.describe("automation.rollover", function()
  t.it("closes a forgotten session at the last activity (E4)", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 21))
    sc.ticks(at(SAT, 3, 59, 50), at(SAT, 3, 59, 55))
    sc.send({ type = "tick" }, at(SAT, 4, 0, 1))
    t.expect(sc.state.open).toBeNil()
    t.expect(sc.state.workday).toBe(SAT)
    t.expect(sc.of("ledger.addSession")[1].session.endS).toBe(at(SAT, 3, 59, 55))
    t.expect(sc.of("ledger.setFlag")[1]).toEqual({ type = "ledger.setFlag", date = FRI, flag = "needsReview", value = true })
    t.expect(sc.state.undo).toBeNil()
  end)

  t.it("closes the session before an overnight sleep (E2)", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 21))
    sc.ticks(at(FRI, 22, 59, 55), at(FRI, 23))
    sc.signal("sleep", at(FRI, 23))
    sc.signal("resume", at(SAT, 8))
    t.expect(sc.state.open).toBeNil()
    t.expect(sc.of("ledger.addSession")[1].session.endS).toBe(at(FRI, 23))
    t.expect(sc.state.pending).toBeNil()
  end)

  t.it("resolves pending absences with unresolved_absence (E22)", function()
    local sc = scenario({ unresolved_absence = "remove" })
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 10))
    sc.signal("unlock", at(FRI, 11))
    sc.signal("lock", at(FRI, 14))
    sc.signal("unlock", at(FRI, 15))
    sc.send({ type = "checkout" }, at(FRI, 17))
    sc.send({ type = "tick" }, at(SAT, 9))
    t.expect(sc.sessions(FRI)).toEqual({
      { at(FRI, 9), at(FRI, 10) },
      { at(FRI, 11), at(FRI, 14) },
      { at(FRI, 15), at(FRI, 17) },
    })
    t.expect(sc.state.pending).toBeNil()
  end)

  t.it("cuts the pending absences of a forgotten session once it is closed", function()
    local sc = scenario({ unresolved_absence = "remove" })
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 12))
    sc.signal("unlock", at(FRI, 13))
    sc.ticks(at(FRI, 18), at(FRI, 18))
    sc.send({ type = "tick" }, at(SAT, 9))
    t.expect(sc.sessions(FRI)).toEqual({ { at(FRI, 9), at(FRI, 12) }, { at(FRI, 13), at(FRI, 18) } })
  end)

  t.it("keeps pending absences as work by default", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 12))
    sc.signal("unlock", at(FRI, 13))
    sc.send({ type = "checkout" }, at(FRI, 17))
    sc.send({ type = "tick" }, at(SAT, 9))
    t.expect(sc.sessions(FRI)).toEqual({ { at(FRI, 9), at(FRI, 17) } })
    t.expect(sc.state.pending).toBeNil()
  end)

  t.it("ignores a clock that went back to the previous day (E7)", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(SAT, 9))
    sc.send({ type = "tick" }, at(FRI, 23))
    t.expect(sc.state.workday).toBe(SAT)
    t.expect(sc.state.open).toBeTruthy()
  end)
end)

t.describe("automation.edits", function()
  local THU = "2026-10-08"

  local function ranges(list)
    local out = {}
    for _, range in list do
      table.insert(out, { startS = range[1], endS = range[2] })
    end
    return out
  end

  t.it("saves a past day, reviews it, and round-trips through undo", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(THU, 9))
    sc.send({ type = "checkout" }, at(THU, 17))
    sc.days[THU].flags.needsReview = true
    local now = at(FRI, 10)
    local edited = { { at(THU, 8, 30), at(THU, 12) }, { at(THU, 13), at(THU, 17, 15) } }
    local result = sc.send({ type = "day.save", date = THU, sessions = ranges(edited) }, now)
    t.expect(result).toEqual({ ok = true, changed = true })
    t.expect(sc.sessions(THU)).toEqual(edited)
    t.expect(sc.days[THU].flags.needsReview).toBeNil()
    t.expect(sc.days[THU].sessions[1].origin).toBe("manual")
    t.expect(sc.state.undo[#sc.state.undo].action).toBe("edit")

    -- Delivered twice: the second save changes nothing.
    t.expect(sc.send({ type = "day.save", date = THU, sessions = ranges(edited) }, now + 1).changed).toBe(false)

    t.expect(sc.send({ type = "undo", id = sc.state.undo[#sc.state.undo].id }, now + 2).ok).toBe(true)
    t.expect(sc.sessions(THU)).toEqual({ { at(THU, 9), at(THU, 17) } })
    t.expect(sc.days[THU].flags.needsReview).toBe(true)
  end)

  t.it("keeps the origin of unchanged sessions", function()
    local sc = scenario()
    sc.days[THU] = Model.newDay()
    Model.addSession(sc.days[THU], { id = Model.sessionId(at(THU, 9)), startS = at(THU, 9), endS = at(THU, 12), origin = "auto" })
    sc.send({ type = "day.save", date = THU, sessions = ranges({ { at(THU, 9), at(THU, 12) }, { at(THU, 13), at(THU, 14) } }) }, at(FRI, 10))
    t.expect(sc.days[THU].sessions[1].origin).toBe("auto")
    t.expect(sc.days[THU].sessions[2].origin).toBe("manual")
  end)

  t.it("rejects invalid days and leaves the ledger alone", function()
    local sc = scenario()
    local result = sc.send({ type = "day.save", date = THU, sessions = ranges({ { at(THU, 12), at(THU, 11) } }) }, at(FRI, 10))
    t.expect(result).toEqual({ ok = false, error = "invalid_order" })
    t.expect(sc.send({ type = "day.save", date = "2026-02-30", sessions = {} }, at(FRI, 10)).error).toBe("invalid_day")
    t.expect(#sc.effects).toBe(0)
  end)

  t.it("moves the start of the running session", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    local result = sc.send({ type = "day.save", date = FRI, sessions = {}, openStartS = at(FRI, 8, 30) }, at(FRI, 10))
    t.expect(result.ok).toBe(true)
    t.expect(sc.state.open).toEqual({ id = Model.sessionId(at(FRI, 8, 30)), startS = at(FRI, 8, 30), origin = "manual" })
    sc.send({ type = "undo" }, at(FRI, 10, 1))
    t.expect(sc.state.open.startS).toBe(at(FRI, 9))
  end)

  t.it("locks a day with pending absences", function()
    local sc = scenario()
    sc.send({ type = "checkin" }, at(FRI, 9))
    sc.signal("lock", at(FRI, 10))
    sc.signal("unlock", at(FRI, 11))
    t.expect(#sc.state.pending).toBe(1)
    t.expect(sc.send({ type = "day.save", date = FRI, sessions = {} }, at(FRI, 11, 5)).error).toBe("pending")
  end)

  t.it("marks days off and missing days, idempotently and undoably", function()
    local sc = scenario()
    t.expect(sc.send({ type = "day.flag", date = THU, flag = "dayOff", value = true }, at(FRI, 10)).changed).toBe(true)
    t.expect(sc.days[THU].flags.dayOff).toBe(true)
    t.expect(sc.send({ type = "day.flag", date = THU, flag = "dayOff", value = true }, at(FRI, 10)).changed).toBe(false)
    sc.send({ type = "undo" }, at(FRI, 10, 1))
    t.expect(sc.days[THU].flags.dayOff).toBe(false)
    t.expect(sc.send({ type = "day.flag", date = THU, flag = "needsReview", value = true }, at(FRI, 10)).error).toBe("invalid_flag")
    sc.send({ type = "day.flag", date = THU, flag = "missingConfirmed", value = true }, at(FRI, 10))
    t.expect(sc.days[THU].flags.missingConfirmed).toBe(true)
  end)

  t.it("evaluates the window afresh when a day off changes today or ahead", function()
    local sc = scenario()
    sc.send({ type = "tick" }, at(FRI, 9))
    t.expect(sc.state.window).toBeTruthy()
    sc.send({ type = "day.flag", date = FRI, flag = "dayOff", value = true }, at(FRI, 9, 1))
    t.expect(sc.state.window).toBeNil()
    sc.send({ type = "tick" }, at(FRI, 9, 2))
    -- Monday's edge was computed ahead: its window must be computed again, undo included.
    sc.send({ type = "day.flag", date = "2026-10-12", flag = "dayOff", value = true }, at(FRI, 9, 3))
    t.expect(sc.state.window).toBeNil()
    sc.send({ type = "tick" }, at(FRI, 9, 4))
    sc.send({ type = "undo" }, at(FRI, 9, 5))
    t.expect(sc.state.window).toBeNil()
    -- A past day changes no edge.
    sc.send({ type = "tick" }, at(FRI, 9, 6))
    sc.send({ type = "day.flag", date = THU, flag = "dayOff", value = true }, at(FRI, 9, 7))
    t.expect(sc.state.window).toBeTruthy()
    -- Nor does saving today without changing its marker; changing it does.
    sc.send({ type = "day.save", date = FRI, sessions = {}, dayOff = true }, at(FRI, 9, 8))
    t.expect(sc.state.window).toBeTruthy()
    sc.send({ type = "day.save", date = FRI, sessions = {}, dayOff = false }, at(FRI, 9, 9))
    t.expect(sc.state.window).toBeNil()
  end)

  t.it("adds and removes adjustments by id", function()
    local sc = scenario()
    local add = { type = "adjust.add", id = "j_1", date = FRI, minutes = -120, note = "  Dentist " }
    t.expect(sc.send(add, at(FRI, 10)).changed).toBe(true)
    t.expect(sc.balance.adjustments).toEqual({ { id = "j_1", date = FRI, minutes = -120, note = "Dentist" } })
    t.expect(sc.send(add, at(FRI, 10)).changed).toBe(false)
    sc.send({ type = "adjust.remove", id = "j_1" }, at(FRI, 10, 1))
    t.expect(#sc.balance.adjustments).toBe(0)
    -- An undo delivered twice reverts the removal only.
    local id = sc.state.undo[#sc.state.undo].id
    sc.send({ type = "undo", id = id }, at(FRI, 10, 2))
    sc.send({ type = "undo", id = id }, at(FRI, 10, 2))
    t.expect(#sc.balance.adjustments).toBe(1)
    t.expect(sc.send({ type = "adjust.add", id = "j_2", date = FRI, minutes = 0 }, at(FRI, 10)).error).toBe("invalid_adjustment")
  end)

  t.it("edits tracking start and initial balance", function()
    local sc = scenario()
    sc.send({ type = "balance.meta", trackingStart = "2026-09-01", initialBalanceMin = 90 }, at(FRI, 10))
    t.expect(sc.balance.trackingStart).toBe("2026-09-01")
    t.expect(sc.balance.initialBalanceMin).toBe(90)
    sc.send({ type = "undo" }, at(FRI, 10, 1))
    t.expect(sc.balance.trackingStart).toBe("2026-10-01")
    t.expect(sc.balance.initialBalanceMin).toBe(0)
    t.expect(sc.send({ type = "balance.meta", trackingStart = "nope" }, at(FRI, 10)).error).toBe("invalid_meta")
  end)
end)

t.finish()
