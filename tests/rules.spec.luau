--!nonstrict
local t = require("./lib/testing.luau")
local Rules = require("../shift/lib/rules.luau")
local Time = require("../shift/lib/time.luau")

local MON_FRI = { true, true, true, true, true, false, false }

local function compile(extra, overrides)
  local settings = {
    workdays = MON_FRI,
    start = "08:00",
    ["end"] = "19:00",
    excludeHolidays = true,
    extraRules = extra or {},
  }
  for key, value in overrides or {} do
    settings[key] = value
  end
  return Rules.compile(settings)
end

local function at(day, hour, min)
  local year, month, d = Time.parseDate(day)
  return Time.localToEpoch(year, month, d, hour, min or 0)
end

-- 2026-10-05 is a Monday.
local function inside(compiled, day, hour, min, calendar)
  return Rules.at(compiled, at(day, hour, min), calendar or Rules.NO_CALENDAR)
end

t.describe("rules.parse", function()
  t.it("parses selectors and time ranges", function()
    t.expect((Rules.parse("+ mon-fri 08:00-19:00"))).toEqual({
      include = true,
      kind = "days",
      days = { true, true, true, true, true, false, false },
      startMin = 8 * 60,
      endMin = 19 * 60,
    })
    t.expect((Rules.parse("- * 12:00-13:30"))).toEqual({ include = false, kind = "all", startMin = 720, endMin = 810 })
    t.expect((Rules.parse("- holidays"))).toEqual({ include = false, kind = "holidays", startMin = 0, endMin = 1440 })
    t.expect((Rules.parse("- 2026-12-24..2027-01-02"))).toEqual({
      include = false,
      kind = "dates",
      from = "2026-12-24",
      to = "2027-01-02",
      startMin = 0,
      endMin = 1440,
    })
    t.expect((Rules.parse("- 2026-12-25") :: any).to).toBe("2026-12-25")
  end)

  t.it("is lenient with case, spaces and a typographic minus", function()
    local rule = Rules.parse("  \u{2212}Sat, SUN  ") :: any
    t.expect(rule.include).toBe(false)
    t.expect(rule.days).toEqual({ false, false, false, false, false, true, true })
    t.expect((Rules.parse("- fri 16:00-24:00") :: any).endMin).toBe(1440)
  end)

  t.it("wraps day ranges", function()
    t.expect((Rules.parse("+ fri-mon") :: any).days).toEqual({ true, false, false, false, true, true, true })
  end)

  t.it("reports why a line is invalid", function()
    local cases = {
      { "mon-fri", "syntax" },
      { "+ mon-fri 08:00-19:00 extra", "syntax" },
      { "+ monday", "selector" },
      { "- 2026-02-30", "date" },
      { "- 2027-01-02..2026-12-24", "range" },
      { "+ * 8-19", "time" },
      { "+ * 24:00-24:00", "time" },
      { "+ * 19:00-08:00", "order" },
      { "+ * 10:00-10:00", "order" },
    }
    for _, case in cases do
      local rule, reason = Rules.parse(case[1])
      t.expect(rule).toBeNil()
      t.expect(reason).toBe(case[2])
    end
  end)
end)

t.describe("rules.window", function()
  t.it("covers the base window on contract workdays", function()
    local compiled = compile()
    t.expect(inside(compiled, "2026-10-05", 7, 59)).toBe(false)
    t.expect(inside(compiled, "2026-10-05", 8, 0)).toBe(true)
    t.expect(inside(compiled, "2026-10-05", 18, 59)).toBe(true)
    t.expect(inside(compiled, "2026-10-05", 19, 0)).toBe(false)
    t.expect(inside(compiled, "2026-10-10", 10, 0)).toBe(false) -- Saturday
  end)

  t.it("lets exclusions win over inclusions", function()
    local compiled = compile({ "- * 12:00-13:30", "+ sat 09:00-12:00" })
    t.expect(inside(compiled, "2026-10-05", 12, 0)).toBe(false)
    t.expect(inside(compiled, "2026-10-05", 13, 30)).toBe(true)
    t.expect(inside(compiled, "2026-10-10", 10, 0)).toBe(true)
    t.expect(inside(compiled, "2026-10-10", 12, 15)).toBe(false)
  end)

  t.it("excludes holidays and days off", function()
    local calendar = {
      isHoliday = function(key)
        return key == "2026-10-06"
      end,
      isDayOff = function(key)
        return key == "2026-10-07"
      end,
    }
    t.expect(inside(compile(), "2026-10-06", 10, 0, calendar)).toBe(false)
    t.expect(inside(compile({}, { excludeHolidays = false }), "2026-10-06", 10, 0, calendar)).toBe(true)
    t.expect(inside(compile({}, { excludeHolidays = false }), "2026-10-07", 10, 0, calendar)).toBe(false)
  end)

  t.it("has no window when start equals end", function()
    local compiled = compile({}, { start = "08:00", ["end"] = "08:00" })
    t.expect(#compiled.errors).toBe(0)
    t.expect(inside(compiled, "2026-10-05", 8, 0)).toBe(false)
  end)

  t.it("skips and reports invalid settings and lines", function()
    local compiled = compile({ "+ sat", "nonsense" }, { start = "8h" })
    t.expect(compiled.errors).toEqual({
      { setting = "window_start", text = "8h", reason = "time" },
      { setting = "extra_rules", index = 2, text = "nonsense", reason = "syntax" },
    })
    t.expect(inside(compiled, "2026-10-05", 10, 0)).toBe(false)
    t.expect(inside(compiled, "2026-10-10", 10, 0)).toBe(true)
    local reversed = compile({}, { start = "19:00", ["end"] = "08:00" })
    t.expect(reversed.errors[1]).toEqual({ setting = "window_end", text = "08:00", reason = "order" })
  end)
end)

t.describe("rules.edges", function()
  t.it("finds the next opening and closing", function()
    local compiled = compile({ "- * 12:00-13:30" })
    local function edge(day, hour, min)
      return Rules.nextEdge(compiled, at(day, hour, min), Rules.NO_CALENDAR)
    end
    t.expect(edge("2026-10-05", 7, 0)).toBe(at("2026-10-05", 8))
    t.expect(edge("2026-10-05", 8, 0)).toBe(at("2026-10-05", 12))
    t.expect(edge("2026-10-05", 12, 10)).toBe(at("2026-10-05", 13, 30))
    t.expect(edge("2026-10-05", 19, 0)).toBe(at("2026-10-06", 8))
    t.expect(edge("2026-10-09", 20, 0)).toBe(at("2026-10-12", 8)) -- Friday evening → Monday
  end)

  t.it("returns nil when nothing changes for a week", function()
    t.expect(Rules.nextEdge(compile({}, { start = "08:00", ["end"] = "08:00" }), at("2026-10-05", 9), Rules.NO_CALENDAR)).toBeNil()
    t.expect(Rules.nextEdge(compile({ "+ *" }, { excludeHolidays = false }), at("2026-10-05", 9), Rules.NO_CALENDAR)).toBeNil()
  end)

  t.it("follows wall-clock times across a DST change", function()
    -- Europe/Paris goes back to winter time on 2026-10-25.
    local compiled = compile({ "+ sun 08:00-09:00" })
    local edge = Rules.nextEdge(compiled, at("2026-10-25", 1, 0), Rules.NO_CALENDAR)
    t.expect(os.date("%H:%M", edge)).toBe("08:00")
  end)
end)

t.describe("rules.preview", function()
  t.it("counts the quarters of each hour inside the window", function()
    local days = Rules.preview(compile({ "- * 12:00-13:30", "- fri 16:15-24:00" }), "2026-10-05", Rules.NO_CALENDAR)
    t.expect(#days).toBe(7)
    t.expect(days[1]).toBe("000000004444024444400000")
    t.expect(days[5]).toBe("000000004444024410000000")
    t.expect(days[6]).toBe(string.rep("0", 24))
  end)
end)

t.finish()
