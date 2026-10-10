--!nonstrict
-- The runner pins TZ=Europe/Paris: DST starts 2026-03-29 02:00 → 03:00 and ends
-- 2026-10-25 03:00 → 02:00.
local t = require("./lib/testing.luau")
local Time = require("../shift/lib/time.luau")

-- 2026-10-09 14:02:00 CEST (UTC+2)
local FRI_AFTERNOON = 1791547320

t.describe("time.dates", function()
  t.it("parses and formats date keys", function()
    t.expect({ Time.parseDate("2026-10-09") }).toEqual({ 2026, 10, 9 })
    t.expect((Time.parseDate("2026-1-9"))).toBeNil()
    t.expect(Time.dateKey(2026, 1, 9)).toBe("2026-01-09")
  end)

  t.it("adds days across months, years and DST changes", function()
    t.expect(Time.addDays("2026-10-31", 1)).toBe("2026-11-01")
    t.expect(Time.addDays("2026-12-31", 1)).toBe("2027-01-01")
    t.expect(Time.addDays("2026-03-01", -1)).toBe("2026-02-28")
    t.expect(Time.addDays("2026-10-24", 2)).toBe("2026-10-26")
    t.expect(Time.daysBetween("2026-10-24", "2026-10-26")).toBe(2)
    t.expect(Time.daysBetween("2026-10-26", "2026-10-24")).toBe(-2)
  end)

  t.it("computes ISO weekdays and week starts", function()
    t.expect(Time.weekday("2026-10-05")).toBe(1) -- Monday
    t.expect(Time.weekday("2026-10-09")).toBe(5)
    t.expect(Time.weekday("2026-10-11")).toBe(7)
    t.expect(Time.weekStart("2026-10-11")).toBe("2026-10-05")
    t.expect(Time.weekStart("2026-10-05")).toBe("2026-10-05")
    t.expect(Time.weekStart("2027-01-01")).toBe("2026-12-28")
  end)
end)

t.describe("time.workdays", function()
  t.it("attributes instants before the day start to the previous workday", function()
    t.expect(Time.workdayOf(FRI_AFTERNOON, 4)).toBe("2026-10-09")
    local saturdayAt0130 = Time.localToEpoch(2026, 10, 10, 1, 30)
    t.expect(Time.workdayOf(saturdayAt0130, 4)).toBe("2026-10-09")
    t.expect(Time.workdayOf(saturdayAt0130, 0)).toBe("2026-10-10")
    t.expect(Time.workdayOf(Time.localToEpoch(2026, 10, 10, 4, 0), 4)).toBe("2026-10-10")
  end)

  t.it("converts local wall-clock times to epochs", function()
    t.expect(Time.localToEpoch(2026, 10, 9, 14, 2)).toBe(FRI_AFTERNOON)
    t.expect(Time.workdayStartS("2026-10-09", 4)).toBe(Time.localToEpoch(2026, 10, 9, 4, 0))
  end)

  t.it("keeps workday lengths true across DST changes", function()
    -- The clocks change at 02:00/03:00, inside the workday that started the day before.
    local autumn = Time.workdayStartS("2026-10-25", 4) - Time.workdayStartS("2026-10-24", 4)
    t.expect(autumn).toBe(25 * 3600)
    local spring = Time.workdayStartS("2026-03-29", 4) - Time.workdayStartS("2026-03-28", 4)
    t.expect(spring).toBe(23 * 3600)
    local normal = Time.workdayStartS("2026-10-26", 4) - Time.workdayStartS("2026-10-25", 4)
    t.expect(normal).toBe(24 * 3600)
  end)

  t.it("moves a time inside the spring DST gap forward", function()
    local inGap = Time.localToEpoch(2026, 3, 29, 2, 30)
    t.expect(os.date("%H:%M", inGap)).toBe("03:30")
  end)
end)

t.finish()
