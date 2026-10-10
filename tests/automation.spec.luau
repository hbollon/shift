--!nonstrict
local t = require("./lib/testing.luau")
local Automation = require("../shift/lib/automation.luau")
local Model = require("../shift/lib/model.luau")
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

t.finish()
