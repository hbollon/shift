--!nonstrict
local t = require("./lib/testing.luau")
local Automation = require("../shift/lib/automation.luau")
local Model = require("../shift/lib/model.luau")
local Time = require("../shift/lib/time.luau")

local SETTINGS = Model.readSettings(function() end)
local NINE = Time.localToEpoch(2026, 10, 9, 9, 0)

local function reduce(state, eventType, nowS)
  return Automation.reduce(state, { type = eventType }, { nowS = nowS, settings = SETTINGS })
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
    local state = {}
    local next, effects, result = reduce(state, "explode", NINE)
    t.expect(next).toBe(state)
    t.expect(#effects).toBe(0)
    t.expect(result).toEqual({ ok = false, error = "unknown_command" })
  end)
end)

t.finish()
