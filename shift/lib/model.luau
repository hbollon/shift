--!nonstrict
-- Domain model: settings, daily targets, sessions and the snapshot published to the UIs
-- (spec §6.5, §6.6, §9.3). Pure: no host access, data comes in as arguments.

local Time = require("./time.luau")
local Types = require("./types.luau")

type AbsenceAction = Types.AbsenceAction
type AwaySignal = Types.AwaySignal
type Day = Types.Day
type Live = Types.Live
type Status = Types.Status
type Session = Types.Session
type Settings = Types.Settings
type Snapshot = Types.Snapshot
type State = Types.State
type UndoEntry = Types.UndoEntry

local Model = {}

local HOUR_MS = 60 * 60 * 1000
local MINUTE_MS = 60 * 1000

-- Snapshot schema version (spec §9.3); fields are only ever added within a version.
Model.SNAPSHOT_VERSION = 1

-- Undo (spec §6.8.4): an action can be undone for 10 minutes, from any surface, and
-- consecutive undos chain while the entries are recent. The stack keeps 20 entries.
Model.UNDO_WINDOW_S = 10 * 60
Model.UNDO_DEPTH = 20

-- Settings -------------------------------------------------------------------

local DAY_SETTINGS = { "workday_mon", "workday_tue", "workday_wed", "workday_thu", "workday_fri", "workday_sat", "workday_sun" }

local WORK_WEEKS = {
  mon_fri = { true, true, true, true, true, false, false },
  mon_sat = { true, true, true, true, true, true, false },
}

local DURATION_FORMATS = { colon = true, units = true, decimal = true }

-- Automation presets (spec §6.3.1); `custom` reads the individual settings.
local PRESETS = {
  manual = { autoCheckin = "off", autoCheckout = "off", idle = "ignore", lock = "ignore", sleep = "ignore" },
  assisted = { autoCheckin = "suggest", autoCheckout = "suggest", idle = "ask", lock = "ask", sleep = "ask" },
  automatic = { autoCheckin = "auto", autoCheckout = "auto", idle = "ask", lock = "ask", sleep = "ask" },
}
local AUTO_MODES = { off = true, suggest = true, auto = true }
local ACTIONS = { ignore = true, ask = true, deduct = true, checkout = true }
local IDLE_BACKENDS = { auto = true, swayidle = true, external = true, off = true }

local function number(value: any, default: number, min: number, max: number): number
  if type(value) ~= "number" or value ~= value then
    return default
  end
  return math.clamp(value, min, max)
end

-- The value when it is one of `allowed`, else `default`.
local function choice(value: any, allowed: { [string]: boolean }, default: string): any
  return allowed[value] and value or default
end

local function strings(value: any): { string }
  local list = {}
  if type(value) == "table" then
    for _, item in value do
      if type(item) == "string" then
        table.insert(list, item)
      end
    end
  end
  return list
end

-- Reads the settings used by the core from `getConfig`, falling back to the manifest
-- defaults (spec §8) for missing or invalid values.
function Model.readSettings(getConfig: (key: string) -> any): Settings
  local workWeek = getConfig("work_week")
  local workdays = WORK_WEEKS[workWeek]
  if workWeek == "custom" then
    workdays = {}
    for i, key in DAY_SETTINGS do
      local value = getConfig(key)
      if type(value) == "boolean" then
        workdays[i] = value
      else
        workdays[i] = WORK_WEEKS.mon_fri[i]
      end
    end
  end
  local preset = choice(getConfig("automation"), { manual = true, assisted = true, automatic = true, custom = true }, "assisted")
  local behavior = PRESETS[preset]
  if not behavior then
    local default = PRESETS.assisted
    behavior = {
      autoCheckin = choice(getConfig("auto_checkin"), AUTO_MODES, default.autoCheckin),
      autoCheckout = choice(getConfig("auto_checkout"), AUTO_MODES, default.autoCheckout),
      idle = choice(getConfig("idle_action"), ACTIONS, default.idle),
      lock = choice(getConfig("lock_action"), ACTIONS, default.lock),
      sleep = choice(getConfig("sleep_action"), ACTIONS, default.sleep),
    }
  end
  local startText, endText = getConfig("window_start"), getConfig("window_end")
  return {
    weeklyHours = number(getConfig("weekly_hours"), 35, 0, 100),
    workdays = workdays or WORK_WEEKS.mon_fri,
    dayStartHour = math.floor(number(getConfig("day_start_hour"), 4, 0, 12)),
    durationFormat = choice(getConfig("duration_format"), DURATION_FORMATS, "colon"),
    preset = preset,
    autoCheckin = behavior.autoCheckin,
    autoCheckout = behavior.autoCheckout,
    actions = { idle = behavior.idle, lock = behavior.lock, sleep = behavior.sleep },
    idleTimeoutMin = math.floor(number(getConfig("idle_timeout_min"), 5, 1, 120)),
    minAbsenceMin = math.floor(number(getConfig("min_absence_min"), 15, 1, 240)),
    unresolvedAbsence = choice(getConfig("unresolved_absence"), { keep = true, remove = true }, "keep"),
    idleBackend = choice(getConfig("idle_backend"), IDLE_BACKENDS, "auto"),
    window = {
      start = type(startText) == "string" and startText or "08:00",
      ["end"] = type(endText) == "string" and endText or "19:00",
      excludeHolidays = getConfig("window_exclude_holidays") ~= false,
      extraRules = strings(getConfig("extra_rules")),
    },
  }
end

-- Whether automation needs signals at all: the manual preset ignores them.
function Model.usesSignals(settings: Settings): boolean
  local actions = settings.actions
  return settings.autoCheckin ~= "off"
    or settings.autoCheckout ~= "off"
    or actions.idle ~= "ignore"
    or actions.lock ~= "ignore"
    or actions.sleep ~= "ignore"
end

-- Targets --------------------------------------------------------------------

-- Weekly hours split evenly over the contract workdays, rounded to the minute (D4).
function Model.dailyTargetMs(settings: Settings): number
  local count = 0
  for _, isWorkday in settings.workdays do
    if isWorkday then
      count += 1
    end
  end
  if count == 0 then
    return 0
  end
  return math.round(settings.weeklyHours * HOUR_MS / count / MINUTE_MS) * MINUTE_MS
end

-- Target of a workday (spec §6.6). `meta.trackingStart` is the first tracked day.
function Model.targetMs(dateKey: string, settings: Settings, meta: { trackingStart: string? }): number
  if meta.trackingStart and dateKey < meta.trackingStart then
    return 0
  end
  if not settings.workdays[Time.weekday(dateKey)] then
    return 0
  end
  return Model.dailyTargetMs(settings)
end

-- Sessions -------------------------------------------------------------------

function Model.newDay(): Day
  return { sessions = {}, flags = {}, note = "" }
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function base36(n: number): string
  local out = ""
  repeat
    local digit = n % 36
    out = string.sub(DIGITS, digit + 1, digit + 1) .. out
    n //= 36
  until n == 0
  return out
end

-- Session ids derive from the start time: sessions never overlap, so starts are unique,
-- and the id of an open session tells whether it already reached the ledger.
function Model.sessionId(startS: number): string
  return "s_" .. base36(startS)
end

-- Inserts a closed session into a day, keeping sessions sorted (spec §6.1 invariants).
-- Returns false and "overlap" when it would overlap an existing session.
function Model.addSession(day: Day, session: Session): (boolean, string?)
  local index = #day.sessions + 1
  for i, other in day.sessions do
    if session.startS < other.endS and other.startS < session.endS then
      return false, "overlap"
    end
    if session.startS < other.startS and index > i then
      index = i
    end
  end
  table.insert(day.sessions, index, session)
  return true
end

-- Removes a session by id; returns whether it was there.
function Model.removeSession(day: Day, id: string): boolean
  for i, session in day.sessions do
    if session.id == id then
      table.remove(day.sessions, i)
      return true
    end
  end
  return false
end

function Model.hasSession(day: Day, id: string): boolean
  for _, session in day.sessions do
    if session.id == id then
      return true
    end
  end
  return false
end

-- Worked time of the recorded sessions of a day (spec §6.5). Removed absences are not
-- part of any session.
function Model.closedWorkedMs(day: Day?): number
  local total = 0
  if day then
    for _, session in day.sessions do
      total += (session.endS - session.startS) * 1000
    end
  end
  return total
end

-- Absences ---------------------------------------------------------------------

-- Precedence of the signals of a merged absence (spec §6.3.5): sleep/gap > lock > idle.
local SIGNAL_RANK = { idle = 1, lock = 2, sleep = 3, gap = 3 }

function Model.strongestSignal(signals: { AwaySignal }): AwaySignal
  local best: AwaySignal = signals[1]
  for _, signal in signals do
    if SIGNAL_RANK[signal] > SIGNAL_RANK[best] then
      best = signal
    end
  end
  return best
end

-- The action configured for the strongest signal; offline gaps follow `sleep`.
function Model.absenceAction(settings: Settings, signals: { AwaySignal }): AbsenceAction
  local signal = Model.strongestSignal(signals)
  if signal == "gap" then
    signal = "sleep"
  end
  return settings.actions[signal]
end

function Model.absenceId(startS: number): string
  return "a_" .. base36(startS)
end

-- Tracking status (spec §6.1): away while an absence that is not ignored is in progress.
function Model.status(state: State, settings: Settings): Status
  if not state.open then
    return "off"
  end
  local absence = state.absence
  if absence and Model.absenceAction(settings, absence.signals) ~= "ignore" then
    return "away"
  end
  return "working"
end

-- Undo -----------------------------------------------------------------------

-- The action an undo would revert now: the top of the stack, if inside the window.
function Model.undoable(state: State, nowS: number): UndoEntry?
  local stack = state.undo
  local top = stack and stack[#stack]
  if top and nowS - top.atS < Model.UNDO_WINDOW_S then
    return top
  end
  return nil
end

-- Snapshot -------------------------------------------------------------------

-- Builds the `shift.snapshot` value (spec §9.3). Counters cover closed sessions only:
-- the UIs add the running part of the open session themselves (`openStartMs`), so the
-- service does not publish every second. The open session counts toward the workday
-- it started on (E3).
export type SnapshotContext = {
  state: State,
  nowS: number,
  settings: Settings,
  meta: { trackingStart: string? },
  dayOf: (dateKey: string) -> Day?, -- recorded day, nil when nothing was recorded
  automation: Types.SnapshotAutomation,
}

function Model.snapshot(ctx: SnapshotContext): Snapshot
  local settings, meta, open = ctx.settings, ctx.meta, ctx.state.open
  local today = Time.workdayOf(ctx.nowS, settings.dayStartHour)
  local todayRecord = ctx.dayOf(today)

  local status = Model.status(ctx.state, settings)
  local since
  if status == "away" then
    since = (ctx.state.absence :: any).startS
  elseif open then
    since = open.startS
  elseif todayRecord and #todayRecord.sessions > 0 then
    since = todayRecord.sessions[#todayRecord.sessions].endS
  end

  -- The open session counts toward the workday it started on; the rollover closes it
  -- when that workday ends, so this only fails between a day change and the next tick.
  local openToday = open and Time.workdayOf(open.startS, settings.dayStartHour) == today
  local openStartS = openToday and open.startS or nil

  local weekStart = Time.weekStart(today)
  local weekWorked, weekTarget = 0, 0
  for offset = 0, 6 do
    local key = Time.addDays(weekStart, offset)
    weekWorked += Model.closedWorkedMs(ctx.dayOf(key))
    weekTarget += Model.targetMs(key, settings, meta)
  end

  local sessions = {}
  for _, session in todayRecord and todayRecord.sessions or {} do
    table.insert(sessions, { startS = session.startS, endS = session.endS })
  end

  local absences, pending = {}, {}
  for _, absence in ctx.state.pending or ({} :: { Types.PendingAbsence }) do
    table.insert(pending, {
      id = absence.id,
      startS = absence.startS,
      endS = absence.endS,
      signal = Model.strongestSignal(absence.signals),
    })
    if absence.date == today then
      table.insert(absences, { startS = absence.startS, endS = absence.endS })
    end
  end

  local undo = Model.undoable(ctx.state, ctx.nowS)
  local suggestion = ctx.state.suggestion

  return {
    v = Model.SNAPSHOT_VERSION,
    status = status,
    since = since,
    today = {
      date = today,
      workedClosedMs = Model.closedWorkedMs(todayRecord),
      openStartMs = openStartS and openStartS * 1000 or nil,
      targetMs = Model.targetMs(today, settings, meta),
      isWorkday = settings.workdays[Time.weekday(today)] == true,
      sessions = sessions,
      absences = absences,
    },
    week = { workedMs = weekWorked, targetMs = weekTarget },
    pending = pending,
    suggestion = suggestion and suggestion.kind or nil,
    undo = undo and { id = undo.id, action = undo.action, atS = undo.atS } or nil,
    automation = ctx.automation,
    contract = {
      weeklyHours = settings.weeklyHours,
      workdays = settings.workdays,
      dailyTargetMs = Model.dailyTargetMs(settings),
    },
    flags = { firstRun = not ctx.state.firstRunDismissed },
    display = { durationFormat = settings.durationFormat },
  }
end

-- Live counters derived from a snapshot at `nowMs` (spec §6.5), computed by the UIs
-- every second. `remainingMs` is counted from the worked time truncated to the minute,
-- so the displayed worked and remaining times always add up to the target.
function Model.live(snapshot: Snapshot, nowMs: number): Live
  local today = snapshot.today
  local running = today.openStartMs and math.max(0, nowMs - today.openStartMs) or 0
  local worked = today.workedClosedMs + running
  local target = today.targetMs
  local remaining = math.max(0, target - worked // MINUTE_MS * MINUTE_MS)
  local eta
  if snapshot.status == "working" and today.openStartMs and worked < target then
    eta = (nowMs + target - worked) // 1000
  end
  return {
    workedMs = worked,
    targetMs = target,
    remainingMs = remaining,
    overtimeMs = math.max(0, worked - target),
    etaS = eta,
    weekWorkedMs = snapshot.week.workedMs + running,
    weekTargetMs = snapshot.week.targetMs,
  }
end

return Model
