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

-- One workday of the ledger. Absences arrive with automation.
export type Day = {
  sessions: { Session },
  absences: { any },
  flags: { [string]: boolean },
  note: string,
}

-- ledger/YYYY.json; days are keyed by "YYYY-MM-DD".
export type Ledger = { schema: number, days: { [string]: Day } }

-- state.json
export type State = { schema: number, heartbeatS: number?, open: OpenSession? }

-- balance.json
export type Balance = {
  schema: number,
  trackingStart: string,
  initialBalanceMin: number,
  adjustments: { any },
}

-- Settings (spec §8) ---------------------------------------------------------------

export type DurationFormat = "colon" | "units" | "decimal"

export type Settings = {
  weeklyHours: number,
  workdays: { boolean }, -- ISO weekday 1 = Monday … 7 = Sunday
  dayStartHour: number,
  durationFormat: DurationFormat,
}

-- Snapshot published on `shift.snapshot` (spec §9.3) ---------------------------------

export type Status = "off" | "working"

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
  },
  week: { workedMs: number, targetMs: number }, -- closed sessions; UIs add the open one
  display: { durationFormat: DurationFormat },
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

export type Event = { type: string, origin: Origin? }

export type Effect =
  { type: "ledger.addSession", date: string, session: Session }
  | { type: "state.save" }
  | { type: "publish" }

export type Result = { ok: boolean, changed: boolean?, error: string? }

export type ReduceContext = { nowS: number, settings: Settings }

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
  setUpdateInterval: (ms: number) -> (),
  togglePanel: (panelId: string) -> (),
  log: (message: string) -> (),
  notifyError: (title: string, body: string?) -> (),
  tr: (key: string, subst: { [string]: any }?) -> string,
}

return {}
