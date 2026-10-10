--!nonstrict
-- The only file that touches the `noctalia` global (spec C10, enforced by `make analyze`).
-- Entries and modules use this table instead, so the tests can pass
-- tests/lib/fake_host.luau in its place, and a change of the beta plugin API is absorbed
-- here. Keep both in sync. The rendering globals of each entry type (`ui`, `barWidget`,
-- `panel`, `shortcut`) are used directly by the entry files.

local Types = require("./types.luau")

local Host = {}

function Host.new(): Types.Host
  return {
    nowMs = noctalia.nowMs,
    formatTime = noctalia.formatTime,
    timeFormat = noctalia.timeFormat,
    state = noctalia.state,
    json = noctalia.json,
    getConfig = noctalia.getConfig,
    pluginDataDir = noctalia.pluginDataDir,
    readFile = noctalia.readFile,
    writeFile = noctalia.writeFile,
    renameFile = noctalia.renameFile,
    fileExists = noctalia.fileExists,
    mkdirAll = noctalia.mkdirAll,
    setUpdateInterval = noctalia.setUpdateInterval,
    togglePanel = noctalia.togglePanel,
    log = noctalia.log,
    notifyError = noctalia.notifyError,
    tr = noctalia.tr,
  }
end

return Host
