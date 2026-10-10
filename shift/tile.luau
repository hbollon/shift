--!nonstrict
-- Shift control-center tile: check in / check out in one click (spec §7.5).

local Host = require("./lib/host.luau")

local DASHBOARD = "hbollon/shift:dashboard"

local host = Host.new()

shortcut.setLabel(host.tr("tile.label"))
shortcut.setIcon("briefcase", "briefcase-off")
shortcut.setActive(false)

function onClick()
  host.togglePanel(DASHBOARD)
end

function onRightClick()
  host.togglePanel(DASHBOARD)
end
