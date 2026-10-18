--!nonstrict
-- Calendar math in local time (spec §6.5). Durations are epoch differences, so they stay
-- correct across DST changes; calendar days are "YYYY-MM-DD" keys, which sort and compare
-- as strings. A workday starts at `dayStartHour` local time: with the default 04:00, a
-- session at 01:30 belongs to the previous workday (spec §6.4, E3).
--
-- Luau's `os.date("*t", s)` gives local fields, but `os.time(fields)` reads them as UTC.
-- Date arithmetic therefore runs entirely in UTC at noon, and local wall-clock times are
-- converted to epochs through the local UTC offset.

local Time = {}

local DAY_S = 24 * 60 * 60

function Time.dateKey(year: number, month: number, day: number): string
  return string.format("%04d-%02d-%02d", year, month, day)
end

-- Splits a "YYYY-MM-DD" key into numbers; nil when the key is malformed.
function Time.parseDate(key: string): (number?, number?, number?)
  local year, month, day = string.match(key, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not year then
    return nil
  end
  return tonumber(year), tonumber(month), tonumber(day)
end

-- Whether `key` is a real calendar date ("2026-02-30" is not).
function Time.isDate(key: any): boolean
  if type(key) ~= "string" then
    return false
  end
  local year, month, day = Time.parseDate(key)
  if not year then
    return false
  end
  local t = os.date("!*t", os.time({ year = year, month = month, day = day, hour = 12 }))
  return t.year == year and t.month == month and t.day == day
end

-- Like parseDate, for keys that must be valid: raises on a malformed key.
local function partsOf(key: string): (number, number, number)
  local year, month, day = Time.parseDate(key)
  assert(year and month and day, "invalid date key: " .. tostring(key))
  return year, month, day
end

-- Epoch of noon UTC on that calendar day: a stable anchor for day arithmetic.
local function utcNoon(key: string): number
  local year, month, day = partsOf(key)
  return os.time({ year = year, month = month, day = day, hour = 12 })
end

function Time.addDays(key: string, days: number): string
  local t = os.date("!*t", utcNoon(key) + days * DAY_S)
  return Time.dateKey(t.year, t.month, t.day)
end

-- Whole days from `from` to `to` (negative when `to` is earlier).
function Time.daysBetween(from: string, to: string): number
  return (utcNoon(to) - utcNoon(from)) // DAY_S
end

-- ISO weekday: 1 = Monday … 7 = Sunday.
function Time.weekday(key: string): number
  local wday = os.date("!*t", utcNoon(key)).wday -- 1 = Sunday
  return (wday + 5) % 7 + 1
end

-- Monday of the ISO week containing `key`.
function Time.weekStart(key: string): string
  return Time.addDays(key, 1 - Time.weekday(key))
end

function Time.year(key: string): number
  return (partsOf(key))
end

-- Local UTC offset in seconds at an instant.
local function utcOffset(epochS: number): number
  return os.time(os.date("*t", epochS)) - epochS
end

-- Epoch of a local wall-clock time. A time inside a DST gap is moved forward by the gap
-- (02:30 → 03:30); a time inside a DST overlap resolves to its second occurrence.
function Time.localToEpoch(year: number, month: number, day: number, hour: number, min: number?): number
  local asUtc = os.time({ year = year, month = month, day = day, hour = hour, min = min or 0, sec = 0 })
  local guess = asUtc - utcOffset(asUtc)
  return asUtc - utcOffset(guess)
end

-- Workday a local instant belongs to.
function Time.workdayOf(epochS: number, dayStartHour: number): string
  local t = os.date("*t", epochS)
  local key = Time.dateKey(t.year, t.month, t.day)
  if t.hour < dayStartHour then
    return Time.addDays(key, -1)
  end
  return key
end

-- Epoch at which a workday starts (its `dayStartHour`, local time).
function Time.workdayStartS(key: string, dayStartHour: number): number
  local year, month, day = partsOf(key)
  return Time.localToEpoch(year, month, day, dayStartHour, 0)
end

return Time
