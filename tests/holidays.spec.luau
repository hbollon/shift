--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Holidays = require("../shift/lib/holidays.luau")

-- 2026-10-09 14:02 CEST
local NOW_MS = 1791547320000
local DAY_MS = 24 * 3600 * 1000

local ANSWER_2026 = [[
[
  {"date":"2026-11-11","localName":"Armistice 1918","name":"Armistice Day","global":true,"counties":null},
  {"date":"2026-12-26","localName":"Saint-Étienne","name":"St. Stephen's Day","global":false,"counties":["FR-57","FR-67","FR-68"]}
]
]]

local function start(options)
  options = options or {}
  local host = FakeHost.new({ nowMs = NOW_MS, env = options.env or { LANG = "fr_FR.UTF-8" } })
  local changes = 0
  local monitor = Holidays.start(host, function()
    changes += 1
  end)
  monitor.configure({
    enabled = options.enabled ~= false,
    country = options.country or "",
    region = options.region or "",
    fromYear = options.fromYear or 2026,
  })
  return host, monitor, function()
    return changes
  end
end

t.describe("holidays.locale", function()
  t.it("reads the country from the locale variables", function()
    local function env(values)
      return function(name)
        return values[name]
      end
    end
    t.expect(Holidays.countryFromLocale(env({ LANG = "fr_FR.UTF-8" }))).toBe("FR")
    t.expect(Holidays.countryFromLocale(env({ LC_TIME = "de_DE.UTF-8", LANG = "en_US.UTF-8" }))).toBe("DE")
    t.expect(Holidays.countryFromLocale(env({ LC_ALL = "C" }))).toBeNil()
    t.expect(Holidays.countryFromLocale(env({}))).toBeNil()
  end)
end)

t.describe("holidays.filter", function()
  t.it("keeps national holidays and the region's own", function()
    local Json = require("./lib/json.luau")
    local entries = Json.decode(ANSWER_2026)
    t.expect(Holidays.filter(entries, "")).toEqual({ ["2026-11-11"] = "Armistice 1918" })
    t.expect(Holidays.filter(entries, "FR-67")).toEqual({ ["2026-11-11"] = "Armistice 1918", ["2026-12-26"] = "Saint-Étienne" })
  end)
end)

t.describe("holidays.fetch", function()
  t.it("fetches every needed year once, then serves the cache", function()
    local host, monitor, changes = start({ fromYear = 2025 })
    monitor.tick()
    t.expect(#host.requests).toBe(1)
    t.expect(host.requests[1].url).toBe("https://date.nager.at/api/v3/PublicHolidays/2025/FR")
    monitor.tick() -- one request at a time
    t.expect(#host.requests).toBe(1)
    host.respond(1, { body = "[]" })
    monitor.tick()
    t.expect(host.requests[2].url).toBe("https://date.nager.at/api/v3/PublicHolidays/2026/FR")
    host.respond(2, { body = ANSWER_2026 })
    t.expect(monitor.holiday("2026-11-11")).toBe("Armistice 1918")
    monitor.tick()
    host.respond(3, { status = 204 })
    monitor.tick()
    t.expect(#host.requests).toBe(3) -- 2025, 2026 and 2027 are cached
    t.expect(monitor.health()).toBe("ok")
    t.expect(changes() >= 3).toBe(true)
    t.expect(host.files["/data/holidays/FR-2026.json"]).toBeTruthy()
  end)

  t.it("reads the cache at startup and refreshes the current years weekly", function()
    local host, monitor = start()
    monitor.tick()
    host.respond(1, { body = ANSWER_2026 })
    monitor.tick()
    host.respond(2, { body = "[]" })

    local restarted = Holidays.start(host, function() end)
    restarted.configure({ enabled = true, country = "", region = "", fromYear = 2026 })
    t.expect(restarted.holiday("2026-11-11")).toBe("Armistice 1918")
    restarted.tick()
    t.expect(#host.requests).toBe(2)
    host.clock.advance(8 * DAY_MS)
    restarted.tick()
    t.expect(#host.requests).toBe(3)
  end)

  t.it("keeps the cache and retries an hour later when a request fails", function()
    local host, monitor = start()
    monitor.tick()
    host.respond(1, { ok = false, status = 0 })
    t.expect(monitor.health()).toBe("error")
    t.expect(monitor.hint()).toBe("holidays")
    monitor.tick()
    t.expect(#host.requests).toBe(2) -- 2027 is still due; 2026 waits
    host.respond(2, { body = "[]" })
    t.expect(monitor.hint()).toBeNil() -- something is cached
    monitor.tick()
    t.expect(#host.requests).toBe(2)
    host.clock.advance(61 * 60 * 1000)
    monitor.tick()
    t.expect(host.requests[3].url).toBe("https://date.nager.at/api/v3/PublicHolidays/2026/FR")
  end)

  t.it("does nothing when disabled or without a country", function()
    local host, monitor = start({ enabled = false })
    monitor.tick()
    t.expect(#host.requests).toBe(0)
    t.expect(monitor.health()).toBe("off")
    local noLocale, unknown = start({ env = { LANG = "C" } })
    unknown.tick()
    t.expect(#noLocale.requests).toBe(0)
    t.expect(unknown.health()).toBe("unavailable")
    t.expect(unknown.hint()).toBe("holidays")
  end)

  t.it("only puts a two-letter code in the request", function()
    local host, monitor = start({ country = "fr/../x" })
    monitor.tick()
    t.expect(#host.requests).toBe(0)
    t.expect(monitor.health()).toBe("unavailable")
  end)
end)

t.finish()
