--!nonstrict
-- Shift dashboard panel: today's counter, history and editors (spec §7.4).

local Host = require("./lib/host.luau")

local host = Host.new()

local function render()
  panel.render(ui.column({ gap = 16 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = host.tr("dashboard.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    }),
    ui.column({ align = "center", gap = 8 }, {
      ui.glyph({ name = "briefcase", size = 48, color = "primary" }),
      ui.label({ text = host.tr("dashboard.placeholder"), color = "on_surface_variant" }),
    }),
  }))
end

function onOpen()
  render()
end
