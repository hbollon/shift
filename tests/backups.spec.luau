--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Backups = require("../shift/lib/backups.luau")
local Time = require("../shift/lib/time.luau")

local ROOT = "/data/backups"

-- A data dir with state, balance and two ledgers, plus files that are not backed up.
local function newHost()
  local host = FakeHost.new({ nowMs = 1791547320000 })
  host.writeFile("/data/state.json", '{"schema":1,"workday":"2026-10-24"}')
  host.writeFile("/data/balance.json", '{"schema":1}')
  host.writeFile("/data/ledger/2025.json", '{"schema":1,"days":{}}')
  host.writeFile("/data/ledger/2026.json", '{"schema":1,"days":{"2026-10-23":{}}}')
  host.writeFile("/data/ledger/2026.json.corrupt-17", "{ not json")
  host.writeFile("/data/holidays/FR-2026.json", "{}")
  host.writeFile("/data/cache/ring-1.svg", "<svg/>")
  return host
end

local function filesUnder(host, dir)
  local names = {}
  for path in host.files do
    if string.sub(path, 1, #dir + 1) == dir .. "/" then
      table.insert(names, string.sub(path, #dir + 2))
    end
  end
  table.sort(names)
  return names
end

local ALL = { "balance.json", "ledger/2025.json", "ledger/2026.json", "state.json" }

t.describe("backups.daily", function()
  t.it("copies every data file as is, into the day's and the month's backups", function()
    local host = newHost()
    t.expect(Backups.new(host, "/data").daily("2026-10-24")).toBe(true)
    t.expect(filesUnder(host, ROOT .. "/daily/2026-10-24")).toEqual(ALL)
    t.expect(filesUnder(host, ROOT .. "/monthly/2026-10")).toEqual(ALL)
    t.expect(host.files[ROOT .. "/daily/2026-10-24/ledger/2026.json"]).toBe(host.files["/data/ledger/2026.json"])
    t.expect(host.listDir(ROOT .. "/daily")).toEqual({ "2026-10-24" })
  end)

  t.it("takes one backup per day, and keeps the month's first", function()
    local host = newHost()
    local backups = Backups.new(host, "/data")
    backups.daily("2026-10-24")
    host.writeFile("/data/balance.json", '{"schema":1,"initialBalanceMin":30}')
    backups.daily("2026-10-24")
    t.expect(host.files[ROOT .. "/daily/2026-10-24/balance.json"]).toBe('{"schema":1}')
    backups.daily("2026-10-25")
    t.expect(host.files[ROOT .. "/daily/2026-10-25/balance.json"]).toBe('{"schema":1,"initialBalanceMin":30}')
    t.expect(host.files[ROOT .. "/monthly/2026-10/balance.json"]).toBe('{"schema":1}')
  end)

  t.it("reuses the oldest backup beyond 30 days, without what it held", function()
    local host = newHost()
    local backups = Backups.new(host, "/data")
    local date = "2026-09-01"
    for _ = 1, 30 do
      backups.daily(date)
      date = Time.addDays(date, 1)
    end
    host.removeFile("/data/ledger/2025.json")
    backups.daily(date)
    local days = host.listDir(ROOT .. "/daily")
    t.expect(#days).toBe(30)
    t.expect(days[1]).toBe("2026-09-02")
    t.expect(days[30]).toBe(date)
    t.expect(filesUnder(host, ROOT .. "/daily/" .. date)).toEqual({ "balance.json", "ledger/2026.json", "state.json" })
  end)

  t.it("keeps 12 months", function()
    local host = newHost()
    local backups = Backups.new(host, "/data")
    for month = 1, 13 do
      backups.daily(string.format("%04d-%02d-01", 2025 + (month - 1) // 12, (month - 1) % 12 + 1))
    end
    local months = host.listDir(ROOT .. "/monthly")
    t.expect(#months).toBe(12)
    t.expect(months[1]).toBe("2025-02")
    t.expect(months[12]).toBe("2026-01")
  end)

  t.it("completes into a backup left unfinished", function()
    local host = newHost()
    host.writeFile(ROOT .. "/daily/2026-10-20.tmp/state.json", "partial")
    host.writeFile(ROOT .. "/daily/2026-10-20.tmp/ledger/2019.json", "stale")
    t.expect(Backups.new(host, "/data").daily("2026-10-24")).toBe(true)
    t.expect(host.listDir(ROOT .. "/daily")).toEqual({ "2026-10-24" })
    t.expect(filesUnder(host, ROOT .. "/daily/2026-10-24")).toEqual(ALL)
    t.expect(host.files[ROOT .. "/daily/2026-10-24/state.json"]).toBe(host.files["/data/state.json"])
  end)

  t.it("never names a backup that failed", function()
    local host = newHost()
    local writeFile = host.writeFile
    host.writeFile = function(path, contents)
      if string.find(path, "ledger/2026", 1, true) then
        return false, "disk full"
      end
      return writeFile(path, contents)
    end
    t.expect(Backups.new(host, "/data").daily("2026-10-24")).toBe(false)
    t.expect(host.listDir(ROOT .. "/daily")).toEqual({ "2026-10-24.tmp" })
    t.expect(host.fileExists(ROOT .. "/monthly/2026-10")).toBe(false)
    host.writeFile = writeFile
    t.expect(Backups.new(host, "/data").daily("2026-10-24")).toBe(true)
    t.expect(host.listDir(ROOT .. "/daily")).toEqual({ "2026-10-24" })
  end)
end)

t.finish()
