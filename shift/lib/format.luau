--!nonstrict
-- Display formatting of durations and clock times (spec §7.2). Durations are shown in
-- whole minutes, truncated toward zero, so a counter never shows time not yet worked.

local Types = require("./types.luau")

local Format = {}

local STYLES = { colon = true, units = true, decimal = true }

-- `style` is the `duration_format` setting: "colon" (7:30), "units" (7h 30m) or
-- "decimal" (7.50 h). Unknown styles fall back to "colon".
function Format.duration(ms: number, style: string?): string
  style = STYLES[style] and style or "colon"
  local minutes = math.abs(ms) // 60000
  local sign = (ms < 0 and minutes > 0) and "-" or ""
  local hours, rest = minutes // 60, minutes % 60
  if style == "units" then
    if hours == 0 then
      return string.format("%s%dm", sign, rest)
    elseif rest == 0 then
      return string.format("%s%dh", sign, hours)
    end
    return string.format("%s%dh %02dm", sign, hours, rest)
  elseif style == "decimal" then
    return string.format("%s%.2f h", sign, minutes / 60)
  end
  return string.format("%s%d:%02d", sign, hours, rest)
end

-- Short form for narrow places such as a vertical bar: "5h", or "42m" under an hour.
function Format.compact(ms: number): string
  local minutes = math.max(0, ms) // 60000
  if minutes < 60 then
    return string.format("%dm", minutes)
  end
  return string.format("%dh", minutes // 60)
end

-- Clock time in the user's 12/24 h preference (`[shell].time_format`).
function Format.clock(host: Types.Host, epochS: number): string
  return host.formatTime(host.timeFormat(), epochS)
end

return Format
