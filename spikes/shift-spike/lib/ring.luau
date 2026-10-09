--!nonstrict
-- S3: progress ring rendered as a generated SVG in palette colors, cached on disk
-- as cache/ring-<size>-<percent>-<paletteHash>.svg (ui.image cannot take data: URIs
-- from plugins: the host prefixes relative paths with the plugin dir).

local M = {}

local function hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  return string.format("%08x", h)
end

function M.palette()
  return {
    track = noctalia.getColor("surface_variant") or "#444444",
    arc = noctalia.getColor("primary") or "#88aaff",
    over = noctalia.getColor("tertiary") or "#ffaa88",
  }
end

local function arc(cx, r, stroke, color, fraction)
  if fraction <= 0 then
    return ""
  end
  local c = 2 * math.pi * r
  return string.format(
    '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" stroke-width="%.2f" '
      .. 'stroke-linecap="round" stroke-dasharray="%.3f %.3f" transform="rotate(-90 %.2f %.2f)"/>',
    cx, cx, r, color, stroke, c * math.min(fraction, 1), c, cx, cx
  )
end

function M.svg(size, progress, colors)
  local stroke = size * 0.12
  local r = (size - stroke) / 2
  local cx = size / 2
  return string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">', size, size, size, size)
    .. string.format(
      '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" stroke-width="%.2f"/>',
      cx, cx, r, colors.track, stroke
    )
    .. arc(cx, r, stroke, colors.arc, progress)
    .. arc(cx, r, stroke, colors.over, progress - 1)
    .. "</svg>"
end

-- Returns an absolute path to the ring for `progress` (0..2), writing it on cache miss.
-- `stats` (optional) receives { hit = bool, ms = number }.
function M.path(size, progress, stats)
  local colors = M.palette()
  local pct = math.clamp(math.floor(progress * 100 + 0.5), 0, 200)
  local key = hash(colors.track .. colors.arc .. colors.over)
  local dir = noctalia.pluginDataDir() .. "/cache"
  local file = string.format("%s/ring-%d-%d-%s.svg", dir, size, pct, key)
  if noctalia.fileExists(file) then
    if stats then
      stats.hit = true
      stats.ms = 0
    end
    return file
  end
  local t0 = noctalia.nowMs()
  noctalia.mkdirAll(dir)
  noctalia.writeFile(file, M.svg(size, pct / 100, colors))
  if stats then
    stats.hit = false
    stats.ms = noctalia.nowMs() - t0
  end
  return file
end

return M
