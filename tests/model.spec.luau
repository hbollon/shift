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
    local meta = { trackingStart = "2026-10-07" }
    t.expect(Model.targetMs("2026-10-06", DEFAULTS, meta)).toBe(0)
    t.expect(Model.targetMs("2026-10-07", DEFAULTS, meta)).toBe(7 * H)
    t.expect(Model.targetMs("2026-10-10", DEFAULTS, meta)).toBe(0) -- Saturday
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

  t.it("subtracts removed absences from worked time", function()
    local day = Model.newDay()
    Model.addSession(day, session("2026-10-09", 9, 0, 12, 0))
    local function absence(id, fromH, toH, status)
      return { id = id, startS = at("2026-10-09", fromH), endS = at("2026-10-09", toH), signals = { "lock" }, status = status, resolvedBy = "user" }
    end
    Model.addAbsence(day, absence("a_2", 14, 15, "removed"))
    Model.addAbsence(day, absence("a_1", 10, 11, "removed"))
    Model.addAbsence(day, absence("a_3", 11, 12, "kept"))
    t.expect(day.absences[1].id).toBe("a_1")
    t.expect(Model.closedWorkedMs(day)).toBe(1 * H)
    -- The 14:00 absence belongs to a session still open since 13:00.
    t.expect(Model.closedWorkedMs(day, at("2026-10-09", 13))).toBe(2 * H)
    t.expect(Model.removedInOpenMs(day, at("2026-10-09", 13))).toBe(1 * H)
    t.expect(Model.removeAbsence(day, "a_1")).toBe(true)
    t.expect(Model.removeAbsence(day, "a_1")).toBe(false)
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
    return Model.snapshot({
      state = state,
      nowS = nowS,
      settings = DEFAULTS,
      meta = { trackingStart = "2026-10-01" },
      dayOf = function(key)
        return days[key]
      end,
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
      removedInOpenMs = 0,
      targetMs = 7 * H,
      isWorkday = true,
      sessions = {},
      absences = {},
    })
    t.expect(snap.pending).toEqual({})
    t.expect(snap.suggestion).toBeNil()
    t.expect(snap.week).toEqual({ workedMs = 0, targetMs = 35 * H })
    t.expect(snap.display).toEqual({ durationFormat = "colon" })
    t.expect(snap.contract.dailyTargetMs).toBe(7 * H)
    t.expect(snap.flags).toEqual({ firstRun = true })
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
    t.expect(snap.undo).toEqual({ id = "checkout:s_1", action = "checkout", atS = at("2026-10-09", 14, 55) })
    t.expect(snap.flags.firstRun).toBe(false)
    t.expect(snapshotAt(at("2026-10-09", 16), state, {}).undo).toBeNil()
  end)

  t.it("reports when the user stopped working", function()
    local friday = Model.newDay()
    Model.addSession(friday, session("2026-10-09", 8, 30, 12, 0))
    local snap = snapshotAt(at("2026-10-09", 15), {}, { ["2026-10-09"] = friday })
    t.expect(snap.since).toBe(at("2026-10-09", 12))
  end)

  t.it("reports absences, pending ones and the away status", function()
    local friday = Model.newDay()
    local open = { id = "s_x", startS = at("2026-10-09", 9), origin = "manual" }
    Model.addAbsence(friday, {
      id = "a_1",
      startS = at("2026-10-09", 10),
      endS = at("2026-10-09", 10, 30),
      signals = { "idle" },
      status = "removed",
      resolvedBy = "user",
    })
    local state = {
      open = open,
      pending = { { id = "a_2", date = "2026-10-09", startS = at("2026-10-09", 11), endS = at("2026-10-09", 12), signals = { "idle", "lock" } } },
      absence = { startS = at("2026-10-09", 14), signals = { "lock" } },
      suggestion = { kind = "checkout" },
    }
    local snap = snapshotAt(at("2026-10-09", 14, 20), state, { ["2026-10-09"] = friday })
    t.expect(snap.status).toBe("away")
    t.expect(snap.since).toBe(at("2026-10-09", 14))
    t.expect(snap.today.removedInOpenMs).toBe(30 * M)
    t.expect(snap.today.workedClosedMs).toBe(0)
    t.expect(snap.pending).toEqual({ { id = "a_2", startS = at("2026-10-09", 11), endS = at("2026-10-09", 12), signal = "lock" } })
    t.expect(snap.today.absences).toEqual({
      { startS = at("2026-10-09", 10), endS = at("2026-10-09", 10, 30), status = "removed" },
      { startS = at("2026-10-09", 11), endS = at("2026-10-09", 12), status = "pending" },
    })
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
      today = { workedClosedMs = 3 * H, openStartMs = openStartMs, removedInOpenMs = 0, targetMs = 7 * H },
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

  t.it("subtracts time removed from the open session", function()
    local s = snap("working", NOW - 2 * H)
    s.today.removedInOpenMs = 30 * M
    t.expect(Model.live(s, NOW).workedMs).toBe(4 * H + 30 * M)
  end)
end)

t.finish()
