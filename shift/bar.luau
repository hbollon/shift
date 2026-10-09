--!nonstrict
-- Shift bar widget: renders the core snapshot and opens the dashboard on click.

local DASHBOARD = "hbollon/shift:dashboard"

local snapshot = noctalia.state.get("shift.snapshot")

local function render()
  local status = snapshot and snapshot.status or "off"
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({ name = status == "off" and "briefcase-off" or "briefcase" }),
    ui.label({ text = "--:--", color = "on_surface_variant" }),
  }))
  barWidget.setTooltip(noctalia.tr("bar.tooltip"))
end

noctalia.state.watch("shift.snapshot", function(value)
  snapshot = value
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(DASHBOARD)
end
