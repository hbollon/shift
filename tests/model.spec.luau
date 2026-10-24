--!nonstrict
local t = require("./lib/testing.luau")
local Model = require("../shift/lib/model.luau")
local Time = require("../shift/lib/time.luau")

local H, M = 3600000, 60000

local function settingsFrom(config)
  return Model.readSettings(function(key)
    return config[key]
  end)
end

local DEFAULTS = settingsFrom({})

-- A book over `days` with the default contract from `trackingStart`.
local function bookOf(days, options)
  options = options or {}
  local trackingStart = options.trackingStart or "2026-10-01"
  return {
    balance = {
      schema = 1,
      trackingStart = trackingStart,
      initialBalanceMin = options.initialMin or 0,
      adjustments = options.adjustments or {},
      contractHistory = options.history or { Model.contract(DEFAULTS, trackingStart) },
    },
    dayOf = function(key)
      return days[key]
    end,
    holiday = function(key)
      return (options.holidays or {})[key]
    end,
  }
end

local function at(day, hour, min)
  local year, month, d = Time.parseDate(day)
  return Time.localToEpoch(year, month, d, hour, min or 0)
end

local function session(day, fromH, fromM, toH, toM)
  local startS = at(day, fromH, fromM)
  return { id = Model.sessionId(startS), startS = startS, endS = at(day, toH, toM), origin = "manual" }
end

t.describe("model.settings", function()
  t.it("falls back to the manifest defaults", function()
    t.expect(DEFAULTS).toEqual({
      weeklyHours = 35,
      workdays = { true, true, true, true, true, false, false },
      dayStartHour = 4,
      durationFormat = "colon",
      preset = "assisted",
      autoCheckin = "suggest",
      autoCheckout = "suggest",
      actions = { idle = "ask", lock = "ask", sleep = "ask" },
      idleTimeoutMin = 5,
      minAbsenceMin = 15,
      unresolvedAbsence = "keep",
      idleBackend = "auto",
      window = { start = "08:00", ["end"] = "19:00", excludeHolidays = true, extraRules = {} },
      holidays = { enabled = true, country = "", region = "" },
      notify = { targetReached = true, pendingAbsence = true, suggestions = true },
    })
  end)

  t.it("applies automation presets", function()
    local manual = settingsFrom({ automation = "manual", auto_checkin = "auto", idle_action = "deduct" })
    t.expect(manual.autoCheckin).toBe("off")
    t.expect(manual.actions).toEqual({ idle = "ignore", lock = "ignore", sleep = "ignore" })
    t.expect(Model.usesSignals(manual)).toBe(false)
    local automatic = settingsFrom({ automation = "automatic" })
    t.expect(automatic.autoCheckin).toBe("auto")
    t.expect(automatic.autoCheckout).toBe("auto")
    t.expect(Model.usesSignals(automatic)).toBe(true)
  end)

  t.it("reads individual behaviors with the custom preset", function()
    local custom = settingsFrom({
      automation = "custom",
      auto_checkin = "auto",
      auto_checkout = "off",
      idle_action = "ignore",
      lock_action = "deduct",
      sleep_action = "bogus",
    })
    t.expect(custom.autoCheckin).toBe("auto")
    t.expect(custom.autoCheckout).toBe("off")
    t.expect(custom.actions).toEqual({ idle = "ignore", lock = "deduct", sleep = "ask" })
  end)

  t.it("keeps only the string rules of the list", function()
    local settings = settingsFrom({ extra_rules = { "- * 12:00-13:00", 42 }, window_end = "18:30" })
    t.expect(settings.window.extraRules).toEqual({ "- * 12:00-13:00" })
    t.expect(settings.window["end"]).toBe("18:30")
  end)

  t.it("resolves work week presets and custom days", function()
    t.expect(settingsFrom({ work_week = "mon_sat" }).workdays).toEqual({ true, true, true, true, true, true, false })
    local custom = settingsFrom({ work_week = "custom", workday_mon = false, workday_sun = true })
    t.expect(custom.workdays).toEqual({ false, true, true, true, true, false, true })
  end)

  t.it("clamps out-of-range numbers", function()
    t.expect(settingsFrom({ weekly_hours = 500, day_start_hour = -3 }).weeklyHours).toBe(100)
    t.expect(settingsFrom({ day_start_hour = 13.6 }).dayStartHour).toBe(12)
    t.expect(settingsFrom({ weekly_hours = "35" }).weeklyHours).toBe(35)
  end)
end)

t.describe("model.targets", function()
  t.it("splits weekly hours evenly over workdays, to the minute", function()
    t.expect(Model.dailyTargetMs(DEFAULTS)).toBe(7 * H)
    t.expect(Model.dailyTargetMs(settingsFrom({ weekly_hours = 39 }))).toBe(7 * H + 48 * M)
    t.expect(Model.dailyTargetMs(settingsFrom({ weekly_hours = 40, work_week = "mon_sat" }))).toBe(6 * H + 40 * M)
    local noDays = settingsFrom({ work_week = "custom", workday_mon = false, workday_tue = false,
      workday_wed = false, workday_thu = false, workday_fri = false })
    t.expect(Model.dailyTargetMs(noDays)).toBe(0)
  end)

  t.it("gives no target before tracking start or outside workdays", function()
    local book = bookOf({}, { trackingStart = "2026-10-07" })
    t.expect(Model.targetMs("2026-10-06", book)).toBe(0)
    t.expect(Model.targetMs("2026-10-07", book)).toBe(7 * H)
    t.expect(Model.targetMs("2026-10-10", book)).toBe(0) -- Saturday
  end)

  t.it("gives no target on public holidays and days off", function()
    local off = Model.newDay()
    off.flags.dayOff = true
    local book = bookOf({ ["2026-10-08"] = off }, { holidays = { ["2026-10-07"] = "Fête" } })
    t.expect(Model.targetMs("2026-10-06", book)).toBe(7 * H)
    t.expect(Model.targetMs("2026-10-07", book)).toBe(0)
    t.expect(Model.targetMs("2026-10-08", book)).toBe(0)
  end)
end)

t.describe("model.contract", function()
  local FOUR_DAYS = settingsFrom({ weekly_hours = 32, work_week = "custom", workday_fri = false })

  t.it("stores daily target minutes per weekday", function()
    t.expect(Model.contract(DEFAULTS, "2026-10-01")).toEqual({
      from = "2026-10-01",
      weeklyHours = 35,
      targets = { 420, 420, 420, 420, 420, 0, 0 },
    })
  end)

  t.it("applies a change from the day it is made, never to past days", function()
    local history = { Model.contract(DEFAULTS, "2026-10-01") }
    t.expect(Model.syncContract(history, DEFAULTS, "2026-10-09")).toBeNil()
    local changed = Model.syncContract(history, FOUR_DAYS, "2026-10-12") :: any
    t.expect(#changed).toBe(2)
    t.expect(changed[2].from).toBe("2026-10-12")
    local book = bookOf({}, { history = changed })
    t.expect(Model.targetMs("2026-10-09", book)).toBe(7 * H) -- Friday, old contract
    t.expect(Model.targetMs("2026-10-16", book)).toBe(0) -- Friday, new contract
    t.expect(Model.targetMs("2026-10-13", book)).toBe(8 * H)
    t.expect(Model.isContractDay("2026-10-16", book.balance)).toBe(false)
  end)

  t.it("replaces a change made the same day, and drops one undone that day", function()
    local history = { Model.contract(DEFAULTS, "2026-10-01") }
    local changed = Model.syncContract(history, FOUR_DAYS, "2026-10-12") :: any
    local again = Model.syncContract(changed, settingsFrom({ weekly_hours = 30 }), "2026-10-12") :: any
    t.expect(#again).toBe(2)
    t.expect(again[2].weeklyHours).toBe(30)
    t.expect(Model.syncContract(again, DEFAULTS, "2026-10-12")).toEqual(history)
  end)

  t.it("starts the history with the first contract", function()
    t.expect(Model.syncContract(nil, DEFAULTS, "2026-10-01")).toEqual({ Model.contract(DEFAULTS, "2026-10-01") })
    -- A change on the first day keeps applying from tracking start.
    local first = { Model.contract(DEFAULTS, "2026-10-01") }
    t.expect((Model.syncContract(first, FOUR_DAYS, "2026-10-01") :: any)[1].from).toBe("2026-10-01")
  end)
end)

-- Hand-computed fixture (exit criterion of the history and balance work): tracking from
-- Thu 2026-10-01, 35 h over Mon–Fri (7:00/day), today Fri 2026-10-09.
t.describe("model.balance", function()
  local function day(sessions, flags)
    local record = Model.newDay()
    for _, range in sessions do
      Model.addSession(record, session(range[1], range[2], range[3], range[4], range[5]))
    end
    for name, value in flags or {} do
      record.flags[name] = value
    end
    return record
  end

  local days = {
    ["2026-10-01"] = day({ { "2026-10-01", 9, 0, 17, 30 } }), -- Thu: 8:30 → +1:30
    ["2026-10-02"] = day({}, { dayOff = true }), -- Fri: day off → 0
    -- Sat 3, Sun 4: no target. Sun has 1:00 of work → +1:00
    ["2026-10-04"] = day({ { "2026-10-04", 10, 0, 11, 0 } }),
    -- Mon 5: holiday → 0
    ["2026-10-06"] = day({ { "2026-10-06", 9, 0, 12, 0 }, { "2026-10-06", 13, 0, 16, 0 } }), -- Tue: 6:00 → −1:00
    -- Wed 7: missing, unreviewed → left out
    ["2026-10-08"] = day({}, { missingConfirmed = true }), -- Thu: confirmed not worked → −7:00
    ["2026-10-09"] = day({ { "2026-10-09", 8, 0, 12, 0 } }), -- Fri: today, excluded
  }
  local book = bookOf(days, {
    holidays = { ["2026-10-05"] = "Holiday" },
    initialMin = 90, -- +1:30
    adjustments = { { id = "j_1", date = "2026-10-06", minutes = -120, note = "Dentist" } }, -- −2:00
  })

  t.it("matches the hand-computed balance", function()
    local summary = Model.balance(book, "2026-10-09")
    -- +1:30 + 1:00 − 1:00 − 7:00 = −5:30
    t.expect(summary.deltaMs).toBe(-(5 * H + 30 * M))
    t.expect(summary.initialMs).toBe(90 * M)
    t.expect(summary.adjustmentsMs).toBe(-120 * M)
    -- −5:30 + 1:30 − 2:00 = −6:00
    t.expect(summary.settledMs).toBe(-6 * H)
    t.expect(summary.toReview).toEqual({ "2026-10-07" })
  end)

  t.it("counts a missing day once it is reviewed", function()
    local reviewed = table.clone(days)
    reviewed["2026-10-07"] = day({}, { missingConfirmed = true })
    local summary = Model.balance(bookOf(reviewed, { holidays = { ["2026-10-05"] = "Holiday" } }), "2026-10-09")
    t.expect(summary.toReview).toEqual({})
    t.expect(summary.deltaMs).toBe(-(12 * H + 30 * M)) -- −5:30 − 7:00
  end)

  t.it("summarises a day for the history", function()
    local summary = Model.daySummary("2026-10-07", book, "2026-10-09")
    t.expect(summary.missing).toBe(true)
    t.expect(summary.targetMs).toBe(7 * H)
    t.expect(Model.daySummary("2026-10-05", book, "2026-10-09").holiday).toBe("Holiday")
    t.expect(Model.daySummary("2026-10-02", book, "2026-10-09").dayOff).toBe(true)
    t.expect(Model.daySummary("2026-10-09", book, "2026-10-09").missing).toBe(false)
    t.expect(Model.daySummary("2026-10-12", book, "2026-10-09").missing).toBe(false) -- future
  end)

  t.it("lists days closed by the rollover", function()
    local flagged = table.clone(days)
    flagged["2026-10-06"] = day({ { "2026-10-06", 9, 0, 12, 0 } }, { needsReview = true })
    t.expect(Model.balance(bookOf(flagged, {}), "2026-10-09").needsReview).toEqual({ "2026-10-06" })
  end)
end)

t.describe("model.validateDay", function()
  local NOW = at("2026-10-09", 15)
  local function check(date, ranges, openStartS)
    local sessions = {}
    for _, range in ranges do
      table.insert(sessions, { startS = range[1], endS = range[2] })
    end
    return { Model.validateDay({ date = date, sessions = sessions, openStartS = openStartS }, 4, NOW) }
  end

  t.it("accepts sessions inside the workday, night sessions included", function()
    t.expect(check("2026-10-08", { { at("2026-10-08", 9), at("2026-10-08", 12) }, { at("2026-10-08", 22), at("2026-10-09", 2) } })).toEqual({})
  end)

  t.it("rejects reversed, out-of-bounds, future and overlapping sessions", function()
    t.expect(check("2026-10-08", { { at("2026-10-08", 12), at("2026-10-08", 12) } })).toEqual({ 1, "order" })
    t.expect(check("2026-10-08", { { at("2026-10-08", 3), at("2026-10-08", 5) } })).toEqual({ 1, "bounds" })
    t.expect(check("2026-10-08", { { at("2026-10-09", 3), at("2026-10-09", 5) } })).toEqual({ 1, "bounds" })
    t.expect(check("2026-10-09", { { at("2026-10-09", 14), at("2026-10-09", 16) } })).toEqual({ 1, "future" })
    t.expect(check("2026-10-08", { { at("2026-10-08", 9), at("2026-10-08", 12) }, { at("2026-10-08", 11), at("2026-10-08", 13) } })).toEqual({ 2, "overlap" })
  end)

  t.it("checks the running session against the closed ones", function()
    t.expect(check("2026-10-09", { { at("2026-10-09", 9), at("2026-10-09", 12) } }, at("2026-10-09", 13))).toEqual({})
    t.expect(check("2026-10-09", { { at("2026-10-09", 9), at("2026-10-09", 12) } }, at("2026-10-09", 11))).toEqual({ 1, "overlap" })
    t.expect(check("2026-10-09", {}, at("2026-10-09", 16))).toEqual({ 0, "future" })
  end)
end)

t.describe("model.sessions", function()
  t.it("derives stable ids from the start time", function()
    t.expect(Model.sessionId(0)).toBe("s_0")
    t.expect(Model.sessionId(1791547320)).toBe("s_tmn2rc")
  end)

  t.it("keeps sessions sorted and rejects overlaps", function()
    local day = Model.newDay()
    t.expect((Model.addSession(day, session("2026-10-09", 14, 0, 18, 0)))).toBe(true)
    t.expect((Model.addSession(day, session("2026-10-09", 9, 0, 12, 0)))).toBe(true)
    t.expect((Model.addSession(day, session("2026-10-09", 12, 0, 14, 0)))).toBe(true)
    t.expect(day.sessions[1].startS).toBe(at("2026-10-09", 9))
    t.expect(day.sessions[2].startS).toBe(at("2026-10-09", 12))
    t.expect(day.sessions[3].startS).toBe(at("2026-10-09", 14))
    t.expect({ Model.addSession(day, session("2026-10-09", 17, 30, 19, 0)) }).toEqual({ false, "overlap" })
    t.expect(#day.sessions).toBe(3)
    t.expect(Model.closedWorkedMs(day)).toBe(9 * H)
    t.expect(Model.hasSession(day, Model.sessionId(at("2026-10-09", 12)))).toBe(true)
    t.expect(Model.removeSession(day, Model.sessionId(at("2026-10-09", 12)))).toBe(true)
    t.expect(Model.removeSession(day, "s_missing")).toBe(false)
    t.expect(#day.sessions).toBe(2)
  end)

  t.it("exposes the top undo entry only inside the window", function()
    local state = { schema = 1, undo = { { id = "a", action = "checkin", atS = 100 }, { id = "b", action = "checkin", atS = 200 } } }
    t.expect((Model.undoable(state, 200 + Model.UNDO_WINDOW_S - 1) :: any).id).toBe("b")
    t.expect(Model.undoable(state, 200 + Model.UNDO_WINDOW_S)).toBeNil()
    t.expect(Model.undoable({ schema = 1 }, 0)).toBeNil()
  end)
end)

t.describe("model.snapshot", function()
  local function snapshotAt(nowS, state, days)
    local book = bookOf(days)
    return Model.snapshot({
      state = state,
      nowS = nowS,
      settings = DEFAULTS,
      book = book,
      balance = Model.balance(book, Time.workdayOf(nowS, 4)),
      automation = {} :: any,
    })
  end

  t.it("describes an off day with no data", function()
    local snap = snapshotAt(at("2026-10-09", 10), {}, {})
    t.expect(snap.status).toBe("off")
    t.expect(snap.since).toBeNil()
    t.expect(snap.today).toEqual({
      date = "2026-10-09",
      workedClosedMs = 0,
      targetMs = 7 * H,
      isWorkday = true,
      dayOff = false,
      sessions = {},
      absences = {},
    })
    t.expect(snap.pending).toEqual({})
    t.expect(snap.suggestion).toBeNil()
    t.expect(snap.week).toEqual({ workedMs = 0, targetMs = 35 * H })
    t.expect(snap.display).toEqual({ durationFormat = "colon" })
    t.expect(snap.contract.dailyTargetMs).toBe(7 * H)
    t.expect(snap.flags).toEqual({ firstRun = true, needsReview = {} })
    -- Oct 1, 2, 5–8 have no session: unreviewed missing days.
    t.expect(snap.balance).toEqual({
      settledMs = 0,
      toReview = { "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08" },
    })
    t.expect(snap.undo).toBeNil()
  end)

  t.it("sums closed sessions of today and of the week", function()
    local thursday, friday = Model.newDay(), Model.newDay()
    Model.addSession(thursday, session("2026-10-08", 9, 0, 17, 0))
    Model.addSession(friday, session("2026-10-09", 8, 30, 12, 0))
    local open = { id = "s_x", startS = at("2026-10-09", 13), origin = "manual" }
    local snap = snapshotAt(at("2026-10-09", 15), { open = open }, { ["2026-10-08"] = thursday, ["2026-10-09"] = friday })
    t.expect(snap.status).toBe("working")
    t.expect(snap.since).toBe(open.startS)
    t.expect(snap.today.workedClosedMs).toBe(3 * H + 30 * M)
    t.expect(snap.today.openStartMs).toBe(open.startS * 1000)
    t.expect(snap.week.workedMs).toBe(11 * H + 30 * M)
    t.expect(snap.today.sessions).toEqual({ { startS = at("2026-10-09", 8, 30), endS = at("2026-10-09", 12) } })
  end)

  t.it("publishes the action an undo would revert", function()
    local state = { open = nil, firstRunDismissed = true, undo = { { id = "checkout:s_1", action = "checkout", atS = at("2026-10-09", 14, 55) } } }
    local snap = snapshotAt(at("2026-10-09", 15), state, {})
    t.expect(snap.undo).toEqual({ id = "checkout:s_1", action = "checkout", kind = "checkout", atS = at("2026-10-09", 14, 55) })
    t.expect(snap.flags.firstRun).toBe(false)
    t.expect(snapshotAt(at("2026-10-09", 16), state, {}).undo).toBeNil()
  end)

  t.it("reports when the user stopped working", function()
    local friday = Model.newDay()
    Model.addSession(friday, session("2026-10-09", 8, 30, 12, 0))
    local snap = snapshotAt(at("2026-10-09", 15), {}, { ["2026-10-09"] = friday })
    t.expect(snap.since).toBe(at("2026-10-09", 12))
  end)

  t.it("reports pending absences and the away status", function()
    local open = { id = "s_x", startS = at("2026-10-09", 9), origin = "manual" }
    local state = {
      open = open,
      pending = {
        { id = "a_1", date = "2026-10-08", startS = at("2026-10-08", 15), endS = at("2026-10-08", 16), signals = { "idle" } },
        { id = "a_2", date = "2026-10-09", startS = at("2026-10-09", 11), endS = at("2026-10-09", 12), signals = { "idle", "lock" } },
      },
      absence = { startS = at("2026-10-09", 14), signals = { "lock" } },
      suggestion = { kind = "checkout" },
    }
    local snap = snapshotAt(at("2026-10-09", 14, 20), state, {})
    t.expect(snap.status).toBe("away")
    t.expect(snap.since).toBe(at("2026-10-09", 14))
    t.expect(snap.pending).toEqual({
      { id = "a_1", startS = at("2026-10-08", 15), endS = at("2026-10-08", 16), signal = "idle" },
      { id = "a_2", startS = at("2026-10-09", 11), endS = at("2026-10-09", 12), signal = "lock" },
    })
    -- The timeline shows today's only.
    t.expect(snap.today.absences).toEqual({ { startS = at("2026-10-09", 11), endS = at("2026-10-09", 12) } })
    t.expect(snap.suggestion).toBe("checkout")
  end)

  t.it("stays working while an ignored absence is in progress", function()
    local open = { id = "s_x", startS = at("2026-10-09", 9), origin = "manual" }
    local manual = settingsFrom({ automation = "manual" })
    local state: any = { open = open, absence = { startS = at("2026-10-09", 10), signals = { "idle" } } }
    t.expect(Model.status(state, manual)).toBe("working")
    t.expect(Model.status(state, DEFAULTS)).toBe("away")
    t.expect(Model.status({} :: any, DEFAULTS)).toBe("off")
  end)

  t.it("ranks signals to pick the absence action", function()
    t.expect(Model.strongestSignal({ "idle", "lock" })).toBe("lock")
    t.expect(Model.strongestSignal({ "lock", "gap", "idle" })).toBe("gap")
    local custom = settingsFrom({ automation = "custom", idle_action = "ignore", lock_action = "deduct", sleep_action = "checkout" })
    t.expect(Model.absenceAction(custom, { "idle" })).toBe("ignore")
    t.expect(Model.absenceAction(custom, { "idle", "lock" })).toBe("deduct")
    t.expect(Model.absenceAction(custom, { "gap" })).toBe("checkout")
  end)

  t.it("counts an open session toward the workday it started on", function()
    local open = { id = "s_x", startS = at("2026-10-08", 22), origin = "manual" }
    local beforeBoundary = snapshotAt(at("2026-10-09", 2), { open = open }, {})
    t.expect(beforeBoundary.today.date).toBe("2026-10-08")
    t.expect(beforeBoundary.today.openStartMs).toBe(open.startS * 1000)
    local afterBoundary = snapshotAt(at("2026-10-09", 9), { open = open }, {})
    t.expect(afterBoundary.today.date).toBe("2026-10-09")
    t.expect(afterBoundary.today.openStartMs).toBeNil()
    t.expect(afterBoundary.status).toBe("working")
  end)
end)

t.describe("model.live", function()
  local function snap(status, openStartMs)
    return {
      status = status,
      today = { workedClosedMs = 3 * H, openStartMs = openStartMs, targetMs = 7 * H },
      week = { workedMs = 20 * H, targetMs = 35 * H },
    }
  end
  local NOW = 1791547320000

  t.it("adds the running session to today and the week", function()
    local live = Model.live(snap("working", NOW - 2 * H - 30 * 1000), NOW)
    t.expect(live.workedMs).toBe(5 * H + 30 * 1000)
    t.expect(live.remainingMs).toBe(2 * H) -- from 5:00, not 5:00:30
    t.expect(live.overtimeMs).toBe(0)
    t.expect(live.etaS).toBe((NOW + 2 * H - 30 * 1000) // 1000)
    t.expect(live.weekWorkedMs).toBe(22 * H + 30 * 1000)
    t.expect(live.weekTargetMs).toBe(35 * H)
  end)

  t.it("has no ETA when off or past the target", function()
    t.expect(Model.live(snap("off", nil), NOW).etaS).toBeNil()
    local over = Model.live(snap("working", NOW - 5 * H), NOW)
    t.expect(over.etaS).toBeNil()
    t.expect(over.remainingMs).toBe(0)
    t.expect(over.overtimeMs).toBe(1 * H)
  end)
end)

t.finish()
