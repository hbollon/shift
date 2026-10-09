--!nonstrict
-- Append-only spike log written to the plugin data dir (Noctalia's own log goes to
-- /dev/null on this machine). One file per entry: spike-<name>.log.

local M = {}

local path = nil
local lines = {}

function M.init(name)
  local dir = noctalia.pluginDataDir()
  path = dir .. "/spike-" .. name .. ".log"
  lines = {}
  local existing = noctalia.readFile(path)
  if existing then
    for line in string.gmatch(existing, "[^\n]+") do
      table.insert(lines, line)
    end
  end
  M.write("---- init " .. name .. " (dataDir=" .. dir .. ")")
end

function M.write(msg)
  local ms = noctalia.nowMs()
  local stamp = os.date("%H:%M:%S", ms // 1000) .. string.format(".%03d", ms % 1000)
  table.insert(lines, stamp .. " " .. msg)
  while #lines > 2000 do
    table.remove(lines, 1)
  end
  noctalia.writeFile(path, table.concat(lines, "\n") .. "\n")
end

return M
