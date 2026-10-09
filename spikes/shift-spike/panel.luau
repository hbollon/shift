--!nonstrict
-- Spike panel: S3 (large SVG ring vs ui.progress fallback, path churn under second
-- ticks) and S4 (openSettings round-trip, rules read-back).

local log = require("./lib/log.luau")
local ring = require("./lib/ring.luau")
log.init("panel")

local progress = 0.72
local animate = false
local seconds = 0

local function rulesText()
  local rules = noctalia.getConfig("schedule_rules")
  if type(rules) ~= "table" then
    return "schedule_rules: " .. type(rules)
  end
  return table.concat(rules, "\n")
end

local function render()
  local stats = {}
  local path = ring.path(160, progress, stats)
  if not stats.hit then
    log.write(string.format("S3 panel ring miss %d%% wrote in %d ms", math.floor(progress * 100 + 0.5), stats.ms))
  end
  local worked = math.floor(progress * 7 * 3600)
  panel.render(ui.column({ gap = 16 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Shift spike", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "settings", variant = "ghost", tooltip = "Open settings (S4)", onClick = function()
        log.write("S4 openSettings()")
        noctalia.openSettings()
      end }),
    }),
    ui.column({ align = "center", gap = 4 }, {
      ui.image({ path = path, width = 160, height = 160 }),
      ui.row({ align = "end", gap = 2 }, {
        ui.label({ text = string.format("%d:%02d", worked // 3600, (worked % 3600) // 60), fontSize = 40, fontWeight = "bold" }),
        ui.label({ text = string.format(":%02d", seconds % 60), fontSize = 16, color = "on_surface_variant" }),
      }),
    }),
    ui.label({ text = "ui.progress fallback", color = "on_surface_variant" }),
    ui.progress({ progress = math.min(progress, 1), height = 8, radius = 4 }),
    ui.row({ gap = 8 }, {
      ui.button({ text = animate and "Stop" or "Animate", variant = "primary", onClick = function()
        animate = not animate
        log.write("S3 panel animate=" .. tostring(animate))
        render()
      end }),
      ui.button({ text = "-10%", variant = "outline", onClick = function()
        progress = math.max(0, progress - 0.1)
        render()
      end }),
      ui.button({ text = "+10%", variant = "outline", onClick = function()
        progress = math.min(2, progress + 0.1)
        render()
      end }),
    }),
    ui.label({ text = "Rules (S4 read-back):", color = "on_surface_variant" }),
    ui.label({ text = rulesText(), maxLines = 8 }),
  }))
end

function onOpen()
  log.write("panel onOpen")
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  log.write("panel onClose")
end

function onIpc(event, payload)
  if event == "animate" then
    animate = not animate
    log.write("S3 panel animate=" .. tostring(animate))
  elseif event == "progress" then
    progress = tonumber(payload) or progress
  end
  render()
end

function update()
  seconds += 1
  if animate then
    progress += 0.01
    if progress > 1.5 then
      progress = 0
    end
  end
  render()
end
