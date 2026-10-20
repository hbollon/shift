--!nonstrict
local t = require("./lib/testing.luau")
local Model = require("../shift/lib/model.luau")
local Time = require("../shift/lib/time.luau")
local Totals = require("../shift/lib/totals.luau")

local DEFAULTS = Model.readSettings(function()
  return nil
end)
local TODAY = "2026-10-20"

local function at(day, hour, min)
  local year, month, d = Time.parseDate(day)
  return Time.localToEpoch(year, month, d, hour, min or 0)
end

local function session(day, fromH, toH)
  local startS = at(day, fromH)
  return { id = Model.sessionId(startS), startS = startS, endS = at(day, toH), origin = "manual" }
end

-- Three months and a half of 7:30 workdays, with a missing day, a day closed by the
-- rollover and a holiday; `reads` counts the day lookups.
local function fixture()
  local days, holidays = {}, { ["2026-08-14"] = "Holiday" }
  local date = "2026-07-06"
  while date < TODAY do
    if Time.weekday(date) <= 5 and date ~= "2026-09-09" then
      days[date] = { sessions = { session(date, 9, 12), session(date, 13, 17) }, flags = {}, note = "" }
      if date == "2026-08-04" then
        days[date].sessions[2].endS = at(date, 18)
        days[date].flags.needsReview = true
      end
    end
    date = Time.addDays(date, 1)
  end
  local f = { days = days, reads = 0 }
  f.book = {
    balance = {
      schema = 1,
      trackingStart = "2026-07-15",
      initialBalanceMin = 90,
      adjustments = { { id = "j_1", date = "2026-08-20", minutes = -120, note = "Dentist" } },
      contractHistory = { Model.contract(DEFAULTS, "2026-07-15") },
    },
    dayOf = function(key)
      f.reads += 1
      return days[key]
    end,
    holiday = function(key)
      return holidays[key]
    end,
  }
  return f
end

local function never()
  return 0
end

t.describe("totals.summary", function()
  t.it("gives what a full pass gives", function()
    local f = fixture()
    local totals = Totals.new(f.book, never)
    local summary = totals.summary(TODAY, 10)
    t.expect(summary).toEqual(Model.balance(f.book, TODAY))
    t.expect(summary.toReview).toEqual({ "2026-09-09" })
    t.expect(summary.needsReview).toEqual({ "2026-08-04" })
  end)

  t.it("reads only the current month again", function()
    local f = fixture()
    local totals = Totals.new(f.book, never)
    totals.summary(TODAY, 10)
    f.reads = 0
    totals.summary(TODAY, 10)
    t.expect(f.reads <= 2 * 19).toBeTruthy() -- 19 days of October, read twice each at most
  end)

  t.it("computes a month again when one of its days changes", function()
    local f = fixture()
    local totals = Totals.new(f.book, never)
    totals.summary(TODAY, 10)
    f.days["2026-08-11"].sessions[2].endS = at("2026-08-11", 19)
    t.expect(totals.summary(TODAY, 10).deltaMs ~= Model.balance(f.book, TODAY).deltaMs).toBeTruthy()
    totals.changed("2026-08-11")
    t.expect(totals.summary(TODAY, 10)).toEqual(Model.balance(f.book, TODAY))
  end)

  t.it("follows the tracking start", function()
    local f = fixture()
    local totals = Totals.new(f.book, never)
    totals.summary(TODAY, 10)
    for _, start in { "2026-08-03", "2026-07-08", "2026-09-01", "2026-10-21" } do
      local balance = table.clone(f.book.balance)
      balance.trackingStart = start
      f.book.balance = balance
      t.expect(totals.summary(TODAY, 10)).toEqual(Model.balance(f.book, TODAY))
    end
  end)

  t.it("keeps the past months when the contract changes from today", function()
    local f = fixture()
    local totals = Totals.new(f.book, never)
    totals.summary(TODAY, 10)
    local balance = table.clone(f.book.balance)
    balance.contractHistory = Model.syncContract(balance.contractHistory, Model.readSettings(function(key)
      return ({ weekly_hours = 30 })[key]
    end), TODAY)
    f.book.balance = balance
    f.reads = 0
    t.expect(totals.summary(TODAY, 10)).toEqual(Model.balance(f.book, TODAY))
    t.expect(f.reads > 19 + 100).toBeTruthy() -- Model.balance's own pass
    f.reads = 0
    totals.summary(TODAY, 10)
    t.expect(f.reads <= 2 * 19).toBeTruthy()
  end)

  t.it("computes everything again when the first contract changes", function()
    local f = fixture()
    local totals = Totals.new(f.book, never)
    totals.summary(TODAY, 10)
    local balance = table.clone(f.book.balance)
    local contract = Model.contract(Model.readSettings(function(key)
      return ({ weekly_hours = 40 })[key]
    end), "2026-07-15")
    balance.contractHistory = { contract }
    f.book.balance = balance
    t.expect(totals.summary(TODAY, 10)).toEqual(Model.balance(f.book, TODAY))
  end)

  t.it("spreads the first pass over calls when it does not fit", function()
    local f = fixture()
    local now = 0
    local totals = Totals.new(f.book, function()
      now += 1 -- one second per reading: one month per call
      return now
    end)
    local calls, summary = 0, nil
    repeat
      calls += 1
      summary = totals.summary(TODAY, 10)
    until summary or calls > 10
    t.expect(calls).toBe(3) -- July, August, then September with October and the result
    t.expect(summary).toEqual(Model.balance(f.book, TODAY))
  end)
end)

t.finish()
