--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Store = require("../shift/lib/store.luau")

local NOW_MS = 1791547320000

local function newHost()
  return FakeHost.new({ nowMs = NOW_MS })
end

t.describe("store.documents", function()
  t.it("starts empty on first run", function()
    local store = Store.new(newHost())
    t.expect(store:loadState()).toEqual({ schema = 1 })
    t.expect(store:loadBalance()).toBeNil()
    t.expect(store:day("2026-10-09")).toBeNil()
  end)

  t.it("round-trips state, balance and ledgers", function()
    local host = newHost()
    local store = Store.new(host)
    t.expect(store:saveState({ schema = 1, heartbeatS = 42, open = { id = "s_1", startS = 1, origin = "manual" } })).toBe(true)
    t.expect(store:saveBalance({ schema = 1, trackingStart = "2026-10-09", initialBalanceMin = 0 })).toBe(true)
    store:day("2026-10-09", function()
      return { sessions = { { id = "s_a", startS = 10, endS = 20, origin = "manual" } } }
    end)
    t.expect(store:saveLedger(2026)).toBe(true)

    local reopened = Store.new(host)
    t.expect(reopened:loadState().open.startS).toBe(1)
    t.expect(reopened:loadBalance().trackingStart).toBe("2026-10-09")
    t.expect(reopened:day("2026-10-09").sessions[1].endS).toBe(20)
    t.expect(host.files["/data/ledger/2026.json"]).toBeTruthy()
  end)

  t.it("keeps ledgers per year", function()
    local host = newHost()
    local store = Store.new(host)
    store:day("2026-12-31", function()
      return { sessions = {} }
    end)
    store:day("2027-01-01", function()
      return { sessions = {} }
    end)
    store:saveLedger(2026)
    store:saveLedger(2027)
    local reopened = Store.new(host)
    t.expect(reopened:day("2026-12-31")).toBeTruthy()
    t.expect(reopened:day("2027-01-01")).toBeTruthy()
    t.expect(reopened:day("2026-01-01")).toBeNil()
  end)

  t.it("writes through a temporary file", function()
    local host = newHost()
    local writes = {}
    local writeFile = host.writeFile
    host.writeFile = function(path, contents)
      table.insert(writes, path)
      return writeFile(path, contents)
    end
    Store.new(host):saveState({ schema = 1 })
    t.expect(writes).toEqual({ "/data/state.json.tmp" })
    t.expect(host.files["/data/state.json.tmp"]).toBeNil()
    t.expect(host.files["/data/state.json"]).toBeTruthy()
  end)
end)

t.describe("store.integrity", function()
  t.it("sets a corrupt file aside and warns once", function()
    local host = newHost()
    host.files["/data/state.json"] = "{ not json"
    local store = Store.new(host)
    t.expect(store:loadState()).toEqual({ schema = 1 })
    t.expect(host.files["/data/state.json"]).toBeNil()
    t.expect(host.files["/data/state.json.corrupt-1791547320"]).toBe("{ not json")
    t.expect(#host.notifications).toBe(1)
    t.expect(host.notifications[1].kind).toBe("error")
    t.expect(store.readOnly).toBe(false)
  end)

  t.it("becomes read-only when a corrupt file cannot be set aside", function()
    local host = newHost()
    host.files["/data/state.json"] = "{ not json"
    host.renameFile = function()
      return false, "read-only file system"
    end
    local store = Store.new(host)
    t.expect(store:loadState()).toEqual({ schema = 1 })
    t.expect(store.readOnly).toBe(true)
    t.expect(store:saveState({ schema = 1 })).toBe(false)
    t.expect(host.files["/data/state.json"]).toBe("{ not json")
  end)

  t.it("treats a document without schema as corrupt", function()
    local host = newHost()
    host.files["/data/balance.json"] = "[1, 2]"
    t.expect(Store.new(host):loadBalance()).toBeNil()
    t.expect(host.files["/data/balance.json.corrupt-1791547320"]).toBe("[1, 2]")
  end)

  t.it("becomes read-only on data from a newer schema", function()
    local host = newHost()
    local newer = '{"schema": 2, "days": {}}'
    host.files["/data/ledger/2026.json"] = newer
    local store = Store.new(host)
    store:day("2026-10-09")
    t.expect(store.readOnly).toBe(true)
    t.expect(store:saveLedger(2026)).toBe(false)
    t.expect(store:saveState({ schema = 1 })).toBe(false)
    t.expect(host.files["/data/ledger/2026.json"]).toBe(newer)
    t.expect(host.files["/data/state.json"]).toBeNil()
  end)

  t.it("becomes read-only when an existing file cannot be read", function()
    local host = newHost()
    host.files["/data/state.json"] = '{"schema": 1}'
    host.readFile = function()
      return nil, "permission denied"
    end
    local store = Store.new(host)
    t.expect(store:loadState()).toEqual({ schema = 1 })
    t.expect(store.readOnly).toBe(true)
    t.expect(host.files["/data/state.json"]).toBe('{"schema": 1}')
  end)

  t.it("reports write failures once", function()
    local host = newHost()
    host.writeFile = function()
      return false, "disk full"
    end
    local store = Store.new(host)
    t.expect(store:saveState({ schema = 1 })).toBe(false)
    t.expect(store:saveState({ schema = 1 })).toBe(false)
    t.expect(#host.notifications).toBe(1)
  end)
end)


t.describe("store.backups", function()
  t.it("restores a damaged file from the newest backup that reads", function()
    local host = FakeHost.new({ nowMs = NOW_MS, translations = { ["errors.store.restored.body"] = "{file} from {date}" } })
    local store = Store.new(host)
    store:saveBalance({ schema = 1, trackingStart = "2026-09-01", initialBalanceMin = 0 })
    store:backup("2026-10-07")
    store:saveBalance({ schema = 1, trackingStart = "2026-09-01", initialBalanceMin = 45 })
    store:backup("2026-10-08")
    host.files["/data/backups/daily/2026-10-08/balance.json"] = "{ damaged too"
    host.files["/data/balance.json"] = "{ not json"

    local reopened = Store.new(host)
    t.expect(reopened:loadBalance().initialBalanceMin).toBe(0)
    t.expect(host.files["/data/balance.json"]).toBe(host.files["/data/backups/daily/2026-10-07/balance.json"])
    t.expect(host.files["/data/balance.json.corrupt-1791547320"]).toBe("{ not json")
    t.expect(#host.notifications).toBe(1)
    t.expect(host.notifications[1].body).toBe("balance.json from 2026-10-07")
    t.expect(reopened.readOnly).toBe(false)
  end)

  t.it("migrates older files after a full backup", function()
    local host = newHost()
    host.writeFile("/data/state.json", '{"schema":1}')
    host.writeFile("/data/ledger/2026.json", '{"schema":1,"days":{"2026-10-08":{"sessions":[]}}}')
    local seen = {}
    local store = Store.new(host, {
      schema = 2,
      migrations = {
        [1] = function(doc, name)
          table.insert(seen, name)
          doc.migrated = true
          return doc
        end,
      },
    })
    t.expect(store:loadState()).toEqual({ schema = 2, migrated = true })
    t.expect(store:day("2026-10-08")).toEqual({ sessions = {} })
    t.expect(seen).toEqual({ "state.json", "ledger/2026.json" })
    t.expect(host.listDir("/data/backups/migration")).toEqual({ "2026-10-09-schema-1" })
    t.expect(host.files["/data/backups/migration/2026-10-09-schema-1/ledger/2026.json"]).toBe(
      '{"schema":1,"days":{"2026-10-08":{"sessions":[]}}}'
    )
    t.expect(store:saveLedger(2026)).toBe(true)
    t.expect(host.json.decode(host.files["/data/ledger/2026.json"]).schema).toBe(2)
  end)

  t.it("does not migrate without a backup", function()
    local host = newHost()
    local original = '{"schema":1}'
    host.writeFile("/data/state.json", original)
    local mkdirAll = host.mkdirAll
    host.mkdirAll = function(path)
      if string.find(path, "migration", 1, true) then
        return false, "read-only file system"
      end
      return mkdirAll(path)
    end
    local store = Store.new(host, { schema = 2, migrations = { [1] = function(doc)
      return doc
    end } })
    t.expect(store:loadState()).toEqual({ schema = 2 })
    t.expect(store.readOnly).toBe(true)
    t.expect(store:saveState({ schema = 2 })).toBe(false)
    t.expect(host.files["/data/state.json"]).toBe(original)
  end)
end)

t.finish()
