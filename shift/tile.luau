--!nonstrict
-- Shift control-center tile (spec §7.5): a check in / check out shortcut showing the
-- status ("Working" / "Off"); today's time is in the bar. Right click opens the dashboard.
--
-- Shortcut entries get no update() ticks: unacknowledged commands are retried when the
-- next snapshot arrives, which the core publishes at least once a minute.

local Commands = require("./lib/commands.luau")
local Host = require("./lib/host.luau")
local Types = require("./lib/types.luau")

local DASHBOARD = "hbollon/shift:dashboard"

local host = Host.new()
local snapshot: Types.Snapshot? = host.state.get("shift.snapshot")

local sender = Commands.sender(host, "tile", function(cmd, err)
  host.log(string.format("tile: command %s failed: %s", tostring(cmd.type), tostring(err)))
  host.notifyError(host.tr("errors.command.title"), host.tr("errors.command.body"))
end)

local function render()
  shortcut.setIcon("briefcase", "briefcase-off")
  if not snapshot then
    shortcut.setLabel(host.tr("tile.label"))
    shortcut.setActive(false)
    return
  end
  local working = snapshot.status == "working"
  shortcut.setLabel(host.tr(working and "status.working" or "status.off"))
  shortcut.setActive(working)
end

host.state.watch("shift.snapshot", function(value)
  snapshot = value
  sender.tick()
  render()
end)

render()

-- Explicit check-in/check-out rather than toggle: a retried command stays harmless.
function onClick()
  local working = snapshot and snapshot.status == "working"
  sender.send({ type = working and "checkout" or "checkin" })
end

function onRightClick()
  host.togglePanel(DASHBOARD)
end
