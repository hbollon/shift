--!nonstrict
-- Shift control-center tile: check in / check out in one click (spec §7.5).

local DASHBOARD = "hbollon/shift:dashboard"

shortcut.setLabel(noctalia.tr("tile.label"))
shortcut.setIcon("briefcase", "briefcase-off")
shortcut.setActive(false)

function onClick()
  noctalia.togglePanel(DASHBOARD)
end

function onRightClick()
  noctalia.togglePanel(DASHBOARD)
end
