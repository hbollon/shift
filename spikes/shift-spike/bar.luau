--!nonstrict
-- Spike bar widget: S3 (SVG ring in the bar) and S5 (state receipt counting, cmd channel).

local log = require("./lib/log.luau")
local ring = require("./lib/ring.luau")
log.init("bar")

local progress = 0.42
local animate = false
local received = 0
local firstMs, lastMs = nil, nil
local cmdSeq = 0

noctalia.state.watch("spike.snapshot", function(snap)
  local now = noctalia.nowMs()
  received += 1
  firstMs = firstMs or now
  lastMs = now
  local n = noctalia.state.get("spike.bench.n") or -1
  if snap.seq == n then
    local sentAt = noctalia.state.get("spike.bench.sentAt") or now
    log.write(string.format("S5 bar received %d snapshots (last seq=%d) first..last=%d ms, sent->last=%d ms",
      received, snap.seq, lastMs - firstMs, lastMs - sentAt))
    received = 0
    firstMs = nil
  end
end)

local sameCounts = { tbl = 0, str = 0 }
noctalia.state.watch("spike.same.tbl", function(v)
  sameCounts.tbl += 1
  log.write(string.format("S5 watch spike.same.tbl fired #%d seq=%s", sameCounts.tbl, tostring(v and v.seq)))
end)
noctalia.state.watch("spike.same.str", function(v)
  sameCounts.str += 1
  log.write(string.format("S5 watch spike.same.str fired #%d value=%s", sameCounts.str, tostring(v)))
end)

local function render()
  local stats = {}
  local path = ring.path(64, progress, stats)
  if not stats.hit then
    log.write(string.format("S3 bar ring miss %d%% wrote in %d ms", math.floor(progress * 100 + 0.5), stats.ms))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.image({ path = path, width = 16, height = 16 }),
    ui.label({ text = string.format("%d%%", math.floor(progress * 100 + 0.5)), fontWeight = "bold" }),
  }))
end

noctalia.setUpdateInterval(1000)

function update()
  if animate then
    progress += 0.05
    if progress > 1.5 then
      progress = 0
    end
  end
  render()
end

function onClick()
  noctalia.togglePanel("hbollon/shift-spike:panel")
end

function onRightClick()
  cmdSeq += 1
  noctalia.state.set("spike.cmd", { seq = cmdSeq, type = "toggle", atMs = noctalia.nowMs() })
end

function onIpc(event, payload)
  if event == "animate" then
    animate = not animate
    log.write("S3 bar animate=" .. tostring(animate))
  elseif event == "progress" then
    progress = tonumber(payload) or progress
    render()
  elseif event == "cmd" then
    -- Same command twice in a row: does the service see both?
    for _ = 1, 2 do
      cmdSeq += 1
      noctalia.state.set("spike.cmd", { seq = cmdSeq, type = "toggle", atMs = noctalia.nowMs() })
    end
  end
end
