--!nonstrict
-- Shared types of the Shift domain. Annotations are checked by `make analyze` (luau-lsp)
-- and cost nothing at runtime. Import them with:
--
--   local Types = require("./types.luau")
--   type Snapshot = Types.Snapshot

-- Persisted documents (spec §10.2) -----------------------------------------------

export type Origin = "manual" | "auto"

-- The running session, kept in state.json until check-out.
export type OpenSession = { id: string, startS: number, origin: Origin }

export type Session = { id: string, startS: number, endS: number, origin: Origin }

-- A signal that reports the user away (spec §6.3.2). `gap` is a clock jump or a service
-- that was not running, treated like `sleep`.
export type AwaySignal = "idle" | "lock" | "sleep" | "gap"

-- A resolved absence of the ledger (spec §6.3.5): `removed` time is not worked.
export type Absence = {
  id: string,
  startS: number,
  endS: number,
  signals: { AwaySignal },
  status: "kept" | "removed",
  resolvedBy: "user" | "auto",
}

-- An absence waiting for the user's decision, counted as work meanwhile. Pending absences
-- live in state.json until resolved, like the open session until check-out.
export type PendingAbsence = {
  id: string,
  date: string, -- workday of the session it interrupted
  startS: number,
  endS: number,
  signals: { AwaySignal },
}

-- One workday of the ledger.
export type Day = {
  sessions: { Session },
  absences: { Absence },
  flags: { [string]: boolean },
  note: string,
}

-- ledger/YYYY.json; days are keyed by "YYYY-MM-DD".
export type Ledger = { schema: number, days: { [string]: Day } }

-- An undoable action (spec §6.8.4). `id` names the action and the session it touched,
-- so an undo command can target it idempotently.
export type UndoEntry =
  { id: string, action: "checkin", atS: number, session: OpenSession }
  | { id: string, action: "checkout", atS: number, session: Session, date: string, recorded: boolean }
  | { id: string, action: "resolve", atS: number, absence: Absence, date: string }

-- What the signals currently say; nil fields are unknown (no backend, or not reported yet).
export type Presence = { idle: boolean?, locked: boolean?, asleep: boolean? }

export type Suggestion = {
  kind: "checkin" | "checkout",
  untilS: number?, -- end of the window segment it belongs to
}

-- state.json
export type State = {
  schema: number,
  heartbeatS: number?,
  workday: string?, -- workday the service last saw, to detect the rollover (spec §6.4)
  open: OpenSession?,
  lastActivityS: number?, -- last instant the user was known to be active
  presence: Presence?,
  absence: { startS: number, signals: { AwaySignal } }?, -- in progress, while a session is open
  pending: { PendingAbsence }?,
  window: { open: boolean, untilS: number? }?, -- last evaluation, to detect window edges
  overrides: {
    suppressCheckinUntilS: number?, -- manual check-out or "Not now" inside a segment
    manualSession: boolean?, -- the open session started outside the window: edges leave it open
  }?,
  suggestion: Suggestion?,
  undo: { UndoEntry }?, -- oldest first, at most Model.UNDO_DEPTH entries
  hints: { [string]: boolean }?, -- dismissed one-time hints
  firstRunDismissed: boolean?,
}

-- balance.json
export type Balance = {
  schema: number,
  trackingStart: string,
  initialBalanceMin: number,
  adjustments: { any },
}

-- Settings (spec §8) ---------------------------------------------------------------

export type DurationFormat = "colon" | "units" | "decimal"

export type Preset = "manual" | "assisted" | "automatic" | "custom"
export type AutoMode = "off" | "suggest" | "auto"
export type AbsenceAction = "ignore" | "ask" | "deduct" | "checkout"
export type IdleBackend = "auto" | "swayidle" | "external" | "off"

export type Settings = {
  weeklyHours: number,
  workdays: { boolean }, -- ISO weekday 1 = Monday … 7 = Sunday
  dayStartHour: number,
  durationFormat: DurationFormat,
  -- Automation (spec §8.3), with the preset already applied.
  preset: Preset,
  autoCheckin: AutoMode,
  autoCheckout: AutoMode,
  actions: { idle: AbsenceAction, lock: AbsenceAction, sleep: AbsenceAction },
  idleTimeoutMin: number,
  minAbsenceMin: number,
  unresolvedAbsence: "keep" | "remove",
  idleBackend: IdleBackend,
  window: { start: string, ["end"]: string, excludeHolidays: boolean, extraRules: { string } },
}

-- Holidays and days off, used by the window (lib/rules.luau).
export type Calendar = {
  isHoliday: (dateKey: string) -> boolean,
  isDayOff: (dateKey: string) -> boolean,
}

-- An invalid window setting or rule line (spec §6.3.3).
export type RuleError = { setting: string, index: number?, text: string, reason: string }

-- Snapshot published on `shift.snapshot` (spec §9.3) ---------------------------------

export type Status = "off" | "working" | "away"

-- State of a signal source: running, polling (logind without gdbus), waiting for IPC
-- (external idle), not available, failing, or turned off.
export type BackendHealth = "ok" | "poll" | "external" | "unavailable" | "error" | "off"

export type Snapshot = {
  v: number,
  status: Status,
  since: number?, -- epoch s of the current status start
  today: {
    date: string,
    workedClosedMs: number,
    openStartMs: number?, -- nil when off, or when the open session started on an earlier workday
    removedInOpenMs: number,
    targetMs: number,
    isWorkday: boolean,
    sessions: { { startS: number, endS: number } }, -- closed sessions, in order
    absences: { { startS: number, endS: number, status: "kept" | "removed" | "pending" } },
  },
  week: { workedMs: number, targetMs: number }, -- closed sessions; UIs add the open one
  pending: { { id: string, startS: number, endS: number, signal: AwaySignal } }, -- oldest first
  suggestion: "checkin" | "checkout" | nil,
  undo: { id: string, action: "checkin" | "checkout" | "resolve", atS: number }?, -- nil once older than the undo window
  automation: SnapshotAutomation,
  contract: { weeklyHours: number, workdays: { boolean }, dailyTargetMs: number },
  flags: { firstRun: boolean },
  display: { durationFormat: DurationFormat },
}

-- Automation summary for the UIs (spec §7.4.6).
export type SnapshotAutomation = {
  preset: Preset,
  idleMin: number,
  window: { start: string, ["end"]: string, extraRules: number },
  backends: { idle: BackendHealth, logind: BackendHealth },
  ruleErrors: { RuleError },
  preview: { string }, -- this week, see Rules.preview
  hints: { string }, -- one-time hints to show ("swayidle")
}

-- Counters derived from a snapshot at a given instant (Model.live).
export type Live = {
  workedMs: number,
  targetMs: number,
  remainingMs: number,
  overtimeMs: number,
  etaS: number?,
  weekWorkedMs: number,
  weekTargetMs: number,
}

-- Reducer (lib/automation.luau) -------------------------------------------------------

-- `type` selects the handler; the other fields are its arguments (see automation.luau).
export type Event = {
  type: string,
  origin: Origin?,
  id: string?,
  keep: boolean?,
  kind: string?,
  signal: string?,
  atS: number?,
  startS: number?,
  endS: number?,
  restarted: boolean?,
}

export type Effect =
  { type: "ledger.addSession", date: string, session: Session }
  | { type: "ledger.removeSession", date: string, id: string }
  | { type: "ledger.addAbsence", date: string, absence: Absence }
  | { type: "ledger.removeAbsence", date: string, id: string }
  | { type: "ledger.setFlag", date: string, flag: string, value: boolean }
  | { type: "state.save" }
  | { type: "publish" }

export type Result = { ok: boolean, changed: boolean?, error: string? }

-- The automation window as the reducer sees it (built from lib/rules.luau).
export type WindowProbe = {
  at: (epochS: number) -> boolean,
  nextEdge: (epochS: number) -> number?, -- nil: no change in sight
}

export type ReduceContext = { nowS: number, settings: Settings, window: WindowProbe? }

-- Commands (lib/commands.luau, spec §9.3) ---------------------------------------------

-- `type` selects the command; other fields are its arguments.
export type Command = { seq: number, type: string, [string]: any }

export type CommandMessage = { from: string, cmds: { Command } }

export type Ack = { seq: number, ok: boolean, error: string? }

-- Host (lib/host.luau, tests/lib/fake_host.luau) ----------------------------------------

export type Host = {
  nowMs: () -> number,
  formatTime: (pattern: string, unixSeconds: number?) -> string,
  timeFormat: () -> string,
  dateFormat: () -> string,
  state: {
    set: (key: string, value: any) -> (),
    get: (key: string) -> any,
    watch: (key: string, callback: (value: any) -> ()) -> (),
  },
  json: {
    decode: (text: string) -> (any, string?),
    encode: (value: any, pretty: boolean?) -> (string?, string?),
  },
  getConfig: (key: string) -> any,
  pluginDataDir: () -> (string?, string?),
  readFile: (path: string) -> (string?, string?),
  writeFile: (path: string, contents: string) -> (boolean, string?),
  renameFile: (from: string, to: string) -> (boolean, string?),
  fileExists: (path: string) -> boolean,
  mkdirAll: (path: string) -> (boolean, string?),
  listDir: (path: string) -> ({ string }?, string?),
  removeFile: (path: string) -> (boolean, string?),
  getColor: (role: string) -> string?,
  openSettings: () -> (),
  setUpdateInterval: (ms: number) -> (),
  togglePanel: (panelId: string) -> (),
  runStream: (cmd: string, onLine: (line: string) -> ()) -> boolean,
  runAsync: (argv: { string }, onResult: ((result: CommandResult) -> ())?, timeoutMs: number?) -> boolean,
  commandExists: (name: string) -> boolean,
  getenv: (name: string) -> string?,
  log: (message: string) -> (),
  notifyError: (title: string, body: string?) -> (),
  tr: (key: string, subst: { [string]: any }?) -> string,
  trp: (key: string, count: number, subst: { [string]: any }?) -> string,
}

export type CommandResult = { exitCode: number, stdout: string, stderr: string, timedOut: boolean }

return {}
