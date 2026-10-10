--!nonstrict
-- Shift bar widget (spec §7.3): today's worked time, live from the core snapshot.
-- Left click opens the dashboard; right click checks in or out.

local Commands = require("./lib/commands.luau")
local Format = require("./lib/format.luau")
local Host = require("./lib/host.luau")
local Model = require("./lib/model.luau")
local Types = require("./lib/types.luau")

local DASHBOARD = "hbollon/shift:dashboard"

local host = Host.new()
local snapshot: Types.Snapshot? = host.state.get("shift.snapshot")
local rendered: string? = nil -- signature of the last rendered content

local sender = Commands.sender(host, "bar", function(cmd, err)
  host.log(string.format("bar: command %s failed: %s", tostring(cmd.type), tostring(err)))
  host.notifyError(host.tr("errors.command.title"), host.tr("errors.command.body"))
end)

local function tooltip(snapshot: Types.Snapshot, live: Types.Live, fmt: Types.DurationFormat): { TooltipRow }
  local rows = {}
  local status = snapshot.status == "working" and "working" or "off"
  local statusText = host.tr("status." .. status)
  if snapshot.since then
    statusText = host.tr("status." .. status .. "_since", { time = Format.clock(host, snapshot.since) })
  end
  table.insert(rows, { key = host.tr("bar.tooltip.status"), value = statusText })

  local today = Format.duration(live.workedMs, fmt)
  if live.targetMs > 0 then
    today = host.tr("bar.tooltip.of_target", { worked = today, target = Format.duration(live.targetMs, fmt) })
  end
  table.insert(rows, { key = host.tr("bar.tooltip.today"), value = today })

  if live.etaS then
    local remaining = host.tr("bar.tooltip.remaining_eta", {
      remaining = Format.duration(live.remainingMs, fmt),
      time = Format.clock(host, live.etaS),
    })
    table.insert(rows, { key = host.tr("bar.tooltip.remaining"), value = remaining })
  elseif live.targetMs > 0 and live.overtimeMs > 0 then
    table.insert(rows, { key = host.tr("bar.tooltip.overtime"), value = "+" .. Format.duration(live.overtimeMs, fmt) })
  end

  local week = host.tr("bar.tooltip.of_target", {
    worked = Format.duration(live.weekWorkedMs, fmt),
    target = Format.duration(live.weekTargetMs, fmt),
  })
  table.insert(rows, { key = host.tr("bar.tooltip.week"), value = week })
  return rows
end

local function render()
  local vertical = barWidget.isVertical()
  if not snapshot then
    -- The core service has not published yet (it is starting or failed to load).
    if rendered ~= "waiting" then
      rendered = "waiting"
      barWidget.render(ui.glyph({ name = "briefcase-off", color = "on_surface_variant" }))
      barWidget.setTooltip(host.tr("bar.waiting"))
    end
    return
  end

  local fmt = snapshot.display.durationFormat
  local live = Model.live(snapshot, host.nowMs())
  local working = snapshot.status == "working"
  local text = vertical and Format.compact(live.workedMs) or Format.duration(live.workedMs, fmt)
  local color = not working and "on_surface_variant" or (live.overtimeMs > 0 and "tertiary" or "primary")

  local rows = tooltip(snapshot, live, fmt)

  -- Re-render only when what is displayed changes, not on every tick.
  local parts = { text, color, tostring(vertical) }
  for _, row in rows do
    table.insert(parts, row.key .. "=" .. row.value)
  end
  local signature = table.concat(parts, "|")
  if signature == rendered then
    return
  end
  rendered = signature

  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = vertical and 2 or 6, align = "center" }, {
    ui.glyph({ name = working and "briefcase" or "briefcase-off", color = color }),
    ui.label({ text = text, color = not working and "on_surface_variant" or nil }),
  }))
  barWidget.setTooltip(rows)
end

host.state.watch("shift.snapshot", function(value)
  snapshot = value
  render()
end)

host.setUpdateInterval(1000)

function update()
  sender.tick()
  render()
end

function onClick()
  host.togglePanel(DASHBOARD)
end

-- Explicit check-in/check-out rather than toggle: a retried command stays harmless.
function onRightClick()
  local working = snapshot and snapshot.status == "working"
  sender.send({ type = working and "checkout" or "checkin" })
end
