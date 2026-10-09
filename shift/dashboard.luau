--!nonstrict
-- Shift dashboard panel: today's counter, history and editors (spec §7.4).

local function render()
  panel.render(ui.column({ gap = 16 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("dashboard.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    }),
    ui.column({ align = "center", gap = 8 }, {
      ui.glyph({ name = "briefcase", size = 48, color = "primary" }),
      ui.label({ text = noctalia.tr("dashboard.placeholder"), color = "on_surface_variant" }),
    }),
  }))
end

function onOpen()
  render()
end
