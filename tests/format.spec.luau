--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Format = require("../shift/lib/format.luau")

local H, M, S = 3600000, 60000, 1000

t.describe("format.duration", function()
  t.it("formats the colon style by default", function()
    t.expect(Format.duration(7 * H + 30 * M, "colon")).toBe("7:30")
    t.expect(Format.duration(5 * M, nil)).toBe("0:05")
    t.expect(Format.duration(0, "colon")).toBe("0:00")
    t.expect(Format.duration(41 * H, "bogus")).toBe("41:00")
  end)

  t.it("splits a duration into numbers and units", function()
    t.expect(Format.parts("7h 05m")).toEqual({ { number = "7", unit = "h" }, { number = "05", unit = "m" } })
    t.expect(Format.parts("45m")).toEqual({ { number = "45", unit = "m" } })
    t.expect(Format.parts("7:30")).toEqual({ { number = "7:30", unit = "" } })
    t.expect(Format.parts("7.50 h")).toEqual({ { number = "7.50", unit = "h" } })
  end)

  t.it("formats the units style", function()
    t.expect(Format.duration(7 * H + 5 * M, "units")).toBe("7h 05m")
    t.expect(Format.duration(7 * H, "units")).toBe("7h")
    t.expect(Format.duration(45 * M, "units")).toBe("45m")
    t.expect(Format.duration(0, "units")).toBe("0m")
  end)

  t.it("formats the decimal style", function()
    t.expect(Format.duration(7 * H + 30 * M, "decimal")).toBe("7.50 h")
    t.expect(Format.duration(20 * M, "decimal")).toBe("0.33 h")
  end)

  t.it("truncates to whole minutes, toward zero", function()
    t.expect(Format.duration(5 * H + 42 * M + 59 * S, "colon")).toBe("5:42")
    t.expect(Format.duration(-(1 * H + 18 * M + 30 * S), "colon")).toBe("-1:18")
    t.expect(Format.duration(-30 * S, "colon")).toBe("0:00")
  end)
end)

t.describe("format.compact", function()
  t.it("shows hours, or minutes under an hour", function()
    t.expect(Format.compact(5 * H + 42 * M)).toBe("5h")
    t.expect(Format.compact(42 * M + 59 * S)).toBe("42m")
    t.expect(Format.compact(-M)).toBe("0m")
  end)
end)

t.describe("format.signed", function()
  t.it("adds a plus sign to positive deltas", function()
    t.expect(Format.signed(23 * M, "colon")).toBe("+0:23")
    t.expect(Format.signed(-(H + 18 * M), "colon")).toBe("-1:18")
    t.expect(Format.signed(30 * S, "colon")).toBe("0:00")
  end)
end)

t.describe("format.workdays", function()
  local NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
  local function days(...)
    local out = { false, false, false, false, false, false, false }
    for _, d in { ... } do
      out[d] = true
    end
    return out
  end

  t.it("collapses runs of three days or more", function()
    t.expect(Format.workdays(days(1, 2, 3, 4, 5), NAMES)).toBe("Mon–Fri")
    t.expect(Format.workdays(days(1, 2, 3, 4, 5, 6, 7), NAMES)).toBe("Mon–Sun")
    t.expect(Format.workdays(days(1, 2, 3, 4, 6), NAMES)).toBe("Mon–Thu, Sat")
  end)

  t.it("lists short runs day by day", function()
    t.expect(Format.workdays(days(1, 3, 5), NAMES)).toBe("Mon, Wed, Fri")
    t.expect(Format.workdays(days(6, 7), NAMES)).toBe("Sat, Sun")
    t.expect(Format.workdays(days(), NAMES)).toBe("")
  end)
end)

t.describe("format.clock", function()
  t.it("uses the shell time format", function()
    local at = os.time({ year = 2026, month = 10, day = 9, hour = 12, min = 2 }) -- 14:02 in Paris
    t.expect(Format.clock(FakeHost.new(), at)).toBe("14:02")
    t.expect(Format.clock(FakeHost.new({ timeFormat = "{:%I:%M %p}" }), at)).toBe("02:02 PM")
  end)
end)

t.finish()
