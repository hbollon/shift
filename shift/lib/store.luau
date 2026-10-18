--!nonstrict
-- Persistence in the plugin data dir (spec §10): state.json, balance.json and one ledger
-- per year in ledger/YYYY.json.
--
-- Data is never lost silently:
-- - writes are atomic (`*.tmp`, then rename onto the real file);
-- - a file that cannot be parsed is moved aside to `*.corrupt-<epoch>` and the user is
--   warned, so a fresh file never overwrites it (if it cannot be moved, the store becomes
--   read-only);
-- - a file written by a newer schema, or one that exists but cannot be read, makes the
--   whole store read-only rather than risk overwriting data it does not understand.

local Time = require("./time.luau")
local Types = require("./types.luau")

type Balance = Types.Balance
type Day = Types.Day
type Host = Types.Host
type Ledger = Types.Ledger
type State = Types.State

local Store = {}
Store.__index = Store

Store.SCHEMA = 1

export type Store = typeof(setmetatable(
  {} :: {
    host: Host,
    dir: string?,
    ledgers: { [number]: Ledger },
    readOnly: boolean,
    warned: { [string]: boolean },
  },
  Store
))

function Store.new(host: Host): Store
  local dir, err = host.pluginDataDir()
  local self = setmetatable({ host = host, dir = dir, ledgers = {}, readOnly = false, warned = {} }, Store)
  if not dir then
    self.readOnly = true
    self:warn("unavailable", tostring(err))
  else
    host.mkdirAll(dir .. "/ledger")
  end
  return self
end

-- Notifies the user once per problem and file.
function Store.warn(self: Store, kind: string, name: string)
  local id = kind .. ":" .. name
  if self.warned[id] then
    return
  end
  self.warned[id] = true
  local host = self.host
  host.log(string.format("store: %s (%s)", kind, name))
  host.notifyError(host.tr("errors.store." .. kind .. ".title"), host.tr("errors.store." .. kind .. ".body", { file = name }))
end

-- read() and write() never get here without a data dir.
function Store.path(self: Store, name: string): string
  return assert(self.dir, "no plugin data dir") .. "/" .. name
end

-- Reads a JSON document; nil when it is missing or had to be set aside.
function Store.read(self: Store, name: string): any
  if not self.dir then
    return nil
  end
  local host, path = self.host, self:path(name)
  if not host.fileExists(path) then
    return nil
  end
  local text = host.readFile(path)
  if text == nil then
    self.readOnly = true
    self:warn("unreadable", name)
    return nil
  end
  local doc = host.json.decode(text)
  if type(doc) ~= "table" or type(doc.schema) ~= "number" then
    if not host.renameFile(path, string.format("%s.corrupt-%d", path, host.nowMs() // 1000)) then
      -- Still in place: writing would destroy the only copy someone could repair.
      self.readOnly = true
      self:warn("corrupt_stuck", name)
      return nil
    end
    self:warn("corrupt", name)
    return nil
  end
  if doc.schema > Store.SCHEMA then
    self.readOnly = true
    self:warn("newer", name)
    return nil
  end
  return doc
end

-- Writes a JSON document atomically. Returns false when nothing was written.
function Store.write(self: Store, name: string, doc: any): boolean
  if self.readOnly then
    return false
  end
  local host, path = self.host, self:path(name)
  local text, encodeErr = host.json.encode(doc, true)
  local ok, err = false, encodeErr
  if text then
    ok, err = host.writeFile(path .. ".tmp", text)
    if ok then
      ok, err = host.renameFile(path .. ".tmp", path)
    end
  end
  if not ok then
    host.log(string.format("store: cannot write %s: %s", name, tostring(err)))
    self:warn("write", name)
  end
  return ok
end

-- Documents ------------------------------------------------------------------

-- Live state; a new one when there is none yet.
function Store.loadState(self: Store): State
  return self:read("state.json") or { schema = Store.SCHEMA }
end

function Store.saveState(self: Store, state: State): boolean
  return self:write("state.json", state)
end

-- Tracking metadata; nil on first run.
function Store.loadBalance(self: Store): Balance?
  return self:read("balance.json")
end

function Store.saveBalance(self: Store, balance: Balance): boolean
  return self:write("balance.json", balance)
end

local function ledgerName(year: number): string
  return string.format("ledger/%d.json", year)
end

function Store.ledger(self: Store, year: number): Ledger
  local ledger = self.ledgers[year]
  if not ledger then
    ledger = self:read(ledgerName(year)) or { schema = Store.SCHEMA, days = {} }
    self.ledgers[year] = ledger
  end
  return ledger
end

-- Record of a workday, or nil when nothing was recorded. With `create`, an empty record
-- built by `create()` is added to the (unsaved) ledger when missing.
function Store.day(self: Store, dateKey: string, create: (() -> Day)?): Day?
  local days = self:ledger(Time.year(dateKey)).days
  if days[dateKey] == nil and create then
    days[dateKey] = create()
  end
  return days[dateKey]
end

-- Replaces the record of a workday (unsaved until saveLedger).
function Store.setDay(self: Store, dateKey: string, day: Day)
  self:ledger(Time.year(dateKey)).days[dateKey] = day
end

function Store.saveLedger(self: Store, year: number): boolean
  return self:write(ledgerName(year), self:ledger(year))
end

return Store
