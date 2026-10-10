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

t.describe("format.clock", function()
  t.it("uses the shell time format", function()
    local at = os.time({ year = 2026, month = 10, day = 9, hour = 12, min = 2 }) -- 14:02 in Paris
    t.expect(Format.clock(FakeHost.new(), at)).toBe("14:02")
    t.expect(Format.clock(FakeHost.new({ timeFormat = "{:%I:%M %p}" }), at)).toBe("02:02 PM")
  end)
end)

t.finish()
