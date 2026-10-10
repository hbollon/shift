--!nonstrict
local t = require("./lib/testing.luau")
local FakeHost = require("./lib/fake_host.luau")
local Ring = require("../shift/lib/ring.luau")

local PALETTE = { on_surface = "#eeeeee", on_surface_variant = "#999999", primary = "#77dd88", tertiary = "#ffaa66" }

local function has(text: string?, pattern: string): boolean
  return text ~= nil and string.find(text, pattern) ~= nil
end

local function count(text, pattern)
  local _, n = string.gsub(text, pattern, "")
  return n
end

t.describe("ring.svg", function()
  local colors = Ring.colors(FakeHost.new({ palette = PALETTE }))

  t.it("draws only the track when empty", function()
    local svg = Ring.svg(16, 2, 0, colors)
    t.expect(count(svg, "<circle")).toBe(1)
    t.expect(has(svg, 'stroke="#eeeeee" stroke%-width="2.00" stroke%-opacity="0.18"')).toBe(true)
  end)

  t.it("draws the progress arc in primary", function()
    local svg = Ring.svg(16, 2, 50, colors)
    t.expect(count(svg, "<circle")).toBe(2)
    t.expect(has(svg, 'stroke="#77dd88"')).toBe(true)
  end)

  t.it("draws overtime as a second lap in tertiary", function()
    local svg = Ring.svg(16, 2, 130, colors)
    t.expect(count(svg, "<circle")).toBe(3)
    t.expect(has(svg, 'stroke="#ffaa66"')).toBe(true)
  end)

  t.it("uses a neutral color when muted", function()
    local muted = Ring.colors(FakeHost.new({ palette = PALETTE }), true)
    t.expect(muted).toEqual({ track = "#eeeeee", arc = "#999999", over = "#999999" })
  end)
end)

t.describe("ring.cache", function()
  t.it("writes a ring once and reuses it", function()
    local host = FakeHost.new({ palette = PALETTE })
    local path = Ring.path(host, 16, 2, 0.424)
    t.expect(string.match(path, "^/data/cache/ring%-r1%-16%-20%-42%-a%-%x+%.svg$")).toBeTruthy()
    t.expect(host.files[path]).toBeTruthy()
    local writes = 0
    host.writeFile = function()
      writes += 1
      return true
    end
    t.expect(Ring.path(host, 16, 2, 0.42)).toBe(path)
    t.expect(writes).toBe(0)
  end)

  t.it("clamps progress to two laps", function()
    local host = FakeHost.new({ palette = PALETTE })
    t.expect(has(Ring.path(host, 16, 2, 3.7), "%-200%-a%-")).toBe(true)
    t.expect(has(Ring.path(host, 16, 2, -1), "%-0%-a%-")).toBe(true)
  end)

  t.it("names rings after the palette", function()
    local palette = table.clone(PALETTE)
    local host = FakeHost.new({ palette = palette })
    local before = Ring.path(host, 16, 2, 0.5)
    palette.primary = "#3366ff"
    t.expect(Ring.path(host, 16, 2, 0.5) == before).toBe(false)
  end)

  t.it("returns nil when the cache cannot be written", function()
    local host = FakeHost.new({ palette = PALETTE })
    host.writeFile = function()
      return false, "read-only"
    end
    t.expect(Ring.path(host, 16, 2, 0.5)).toBeNil()
  end)

  t.it("prunes rings of other palettes and older versions", function()
    local palette = table.clone(PALETTE)
    local host = FakeHost.new({ palette = palette })
    local old = Ring.path(host, 16, 2, 0.5)
    host.files["/data/cache/ring-r0-16-20-50-a-00000000.svg"] = "<svg/>"
    host.files["/data/cache/notes.txt"] = "keep me"
    palette.primary = "#3366ff"
    local current = Ring.path(host, 16, 2, 0.5)
    t.expect(Ring.prune(host)).toBe(2)
    t.expect(host.files[old]).toBeNil()
    t.expect(host.files[current]).toBeTruthy()
    t.expect(host.files["/data/cache/notes.txt"]).toBe("keep me")
  end)
end)

t.finish()
