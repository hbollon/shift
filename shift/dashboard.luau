--!nonstrict
-- Shift dashboard panel (spec §7.4): header with undo, status, attention cards, first-run
-- card, hero ring with the live counter and the check in/out button, stat tiles, today's
-- timeline, and the automation footer with its details. It renders the core snapshot
-- every second while open and sends actions as commands.

local Commands = require("./lib/commands.luau")
local Format = require("./lib/format.luau")
local Host = require("./lib/host.luau")
local Model = require("./lib/model.luau")
local Overlay = require("./lib/ui/overlay.luau")
local Ring = require("./lib/ring.luau")
local Types = require("./lib/types.luau")

type Snapshot = Types.Snapshot
type Live = Types.Live

local HERO_RING = 168
local HERO_STROKE = 11
-- Space between the ring and the check-in button.
local HERO_BUTTON_GAP = 14
local COUNTER_SIZE = 36
local COUNTER_MIN = 22
-- Width the counter may take inside the ring. The lines below it lift it above the
-- center, where the ring is narrower.
local COUNTER_ROOM = HERO_RING - 2 * HERO_STROKE - 24
local UNIT_SCALE = 0.55 -- unit letters next to the counter's numbers
local SECONDS_SIZE = 16
local COUNTER_GAP = 2
-- A label's text baseline sits this many font sizes above the bottom of its box (half of
-- line height minus cap height, DejaVu-like metrics), so a small label next to a large one
-- in a bottom-aligned row is raised by this ratio of their size difference.
local BASELINE_RATIO = 0.22
local DETAIL_SIZE = 13
local RADIUS = 12
local ROW_HEIGHT = 22
local ROW_GAP = 6
-- Attention cards shown at once; the rest are counted.
local MAX_CARDS = 3
local PREVIEW_LABEL = 32

local host = Host.new()
local snapshot: Snapshot? = host.state.get("shift.snapshot")
local isOpen = false
local commandError: string? = nil -- shown inline until the next action
local detailsOpen = false -- the automation details replace the dashboard body

local render -- forward declaration: commands re-render on failure

local sender = Commands.sender(host, "dashboard", function(cmd, err)
  host.log(string.format("dashboard: command %s failed: %s", tostring(cmd.type), tostring(err)))
  commandError = err == "nothing_to_undo" and host.tr("panel.errors.undo_expired") or host.tr("panel.errors.command")
  if isOpen then
    render()
  end
end)

local function send(cmd: { [string]: any })
  commandError = nil
  sender.send(cmd)
end

local function clock(epochS: number): string
  return Format.clock(host, epochS)
end

-- Header -----------------------------------------------------------------------

local function undoLabel(undo): string
  return host.tr("panel.undo." .. undo.kind, { time = clock(undo.atS), date = undo.date or "" })
end

local function header(snap: Snapshot, nowS: number): UiNode
  local undo = snap.undo
  local canUndo = undo ~= nil and nowS - undo.atS < Model.UNDO_WINDOW_S
  return ui.row({ align = "center", gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = host.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = host.formatTime(host.dateFormat(), nowS), fontSize = 12, color = "on_surface_variant" }),
    }),
    ui.button({
      glyph = "history",
      variant = "ghost",
      visible = canUndo,
      tooltip = canUndo and undoLabel(undo) or nil,
      onClick = function()
        if snapshot and snapshot.undo then
          send({ type = "undo", id = snapshot.undo.id })
        end
      end,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = host.tr("panel.settings"),
      onClick = function()
        host.openSettings()
      end,
    }),
  })
end

local DOT_COLORS = { working = "primary", away = "secondary", off = "on_surface_variant" }

-- Status chip, with the estimated end of the day on the right while working.
local function statusChip(snap: Snapshot, live: Live, nowS: number): UiNode
  local status = snap.status
  local text
  if status == "away" and snap.since then
    local minutes = (nowS - snap.since) // 60
    if minutes < 60 then
      text = host.trp("panel.status.away_for", minutes)
    else
      text = host.tr("panel.status.away_since", { time = clock(snap.since) })
    end
  elseif status == "working" and snap.since then
    text = host.tr("panel.status.working_since", { time = clock(snap.since) })
  elseif snap.since then
    text = host.tr("panel.status.off_since", { time = clock(snap.since) })
  else
    text = host.tr("panel.status.off")
  end
  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 8, paddingH = 10, paddingV = 4, radius = 999, fill = "surface_variant" }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = DOT_COLORS[status] }),
      ui.label({ text = text, fontSize = 12 }),
    }),
    ui.label({
      text = live.etaS and host.tr("panel.hero.done_at", { time = clock(live.etaS) }) or "",
      fontSize = 12,
      color = "on_surface_variant",
    }),
  })
end

-- Attention cards (spec §7.4.2) -------------------------------------------------------

-- "42 min" under an hour, else a duration in the user's format.
local function shortDuration(ms: number, fmt: Types.DurationFormat): string
  local minutes = ms // 60000
  if minutes < 60 then
    return host.trp("panel.attention.minutes", minutes)
  end
  return Format.duration(ms, fmt)
end

local function smallButton(text: string, variant: string, onClick: () -> ()): UiNode
  return ui.button({ text = text, variant = variant, controlSize = "sm", onClick = onClick })
end

local function card(glyph: string, text: string, actions: { UiNode }): UiNode
  local children = {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = glyph, color = "secondary" }),
      ui.label({ text = text, flexGrow = 1, maxLines = 2, fontSize = 13 }),
    }),
  }
  if #actions > 0 then
    table.insert(children, ui.row({ gap = 8, justify = "end" }, actions))
  end
  return ui.column({ gap = 8, padding = 12, radius = RADIUS, fill = "surface_variant" }, children)
end

-- Cards in priority order: a suggestion, pending absences (most recent first), invalid
-- settings, then one-time hints.
local function attentionCards(snap: Snapshot, nowS: number): { UiNode }
  local fmt = snap.display.durationFormat
  local cards = {}
  local suggestion = snap.suggestion
  if suggestion then
    local checkin = suggestion == "checkin"
    table.insert(cards, card(checkin and "clock-play" or "clock-pause", host.tr("panel.attention.suggest_" .. suggestion, { time = clock(nowS) }), {
      smallButton(host.tr("panel.attention.not_now"), "ghost", function()
        send({ type = "suggestion.dismiss", kind = suggestion })
      end),
      smallButton(host.tr(checkin and "panel.checkin" or "panel.checkout"), checkin and "primary" or "outline", function()
        send({ type = checkin and "checkin" or "checkout" })
      end),
    }))
  end
  for index = #snap.pending, 1, -1 do
    local absence = snap.pending[index]
    local text = host.tr("panel.attention.away", {
      from = clock(absence.startS),
      to = clock(absence.endS),
      duration = shortDuration((absence.endS - absence.startS) * 1000, fmt),
    }) .. " · " .. host.tr("panel.attention.signal." .. absence.signal)
    table.insert(cards, card("clock-exclamation", text, {
      smallButton(host.tr("panel.attention.remove"), "ghost", function()
        send({ type = "absence.resolve", id = absence.id, keep = false })
      end),
      smallButton(host.tr("panel.attention.keep"), "outline", function()
        send({ type = "absence.resolve", id = absence.id, keep = true })
      end),
    }))
  end
  local errors = #snap.automation.ruleErrors
  if errors > 0 then
    table.insert(cards, card("alert-triangle", host.trp("panel.attention.rule_errors", errors), {
      smallButton(host.tr("panel.attention.edit_settings"), "outline", function()
        host.openSettings()
      end),
    }))
  end
  for _, hint in snap.automation.hints do
    table.insert(cards, card("info-circle", host.tr("panel.attention." .. hint), {
      smallButton(host.tr("panel.attention.dismiss"), "ghost", function()
        send({ type = "hint.dismiss", id = hint })
      end),
    }))
  end
  if #cards > MAX_CARDS then
    local more = #cards - MAX_CARDS
    cards = { table.unpack(cards, 1, MAX_CARDS) }
    table.insert(cards, ui.label({ text = host.trp("panel.attention.more", more), fontSize = 12, color = "on_surface_variant" }))
  end
  return cards
end

-- First-run card (spec §6.10) ------------------------------------------------------

local function dayNames(): { string }
  local names = {}
  for _, key in { "mon", "tue", "wed", "thu", "fri", "sat", "sun" } do
    table.insert(names, host.tr("days.short." .. key))
  end
  return names
end

local function welcomeCard(snap: Snapshot): UiNode
  local contract = snap.contract
  local fmt = snap.display.durationFormat
  local summary = host.tr("panel.welcome.contract", {
    hours = Format.duration(contract.weeklyHours * 3600000, fmt),
    days = Format.workdays(contract.workdays, dayNames()),
    daily = Format.duration(contract.dailyTargetMs, fmt),
  })
  return ui.column({ gap = 10, padding = 14, radius = RADIUS, fill = "surface_variant" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "briefcase", color = "primary" }),
      ui.label({ text = host.tr("panel.welcome.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = host.tr("panel.welcome.dismiss"),
        onClick = function()
          send({ type = "onboarding.dismiss" })
        end,
      }),
    }),
    ui.label({ text = host.tr("panel.welcome.body"), maxLines = 3 }),
    ui.label({ text = summary, color = "on_surface_variant", fontSize = 12, maxLines = 2 }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = host.tr("panel.welcome.checkin"),
        glyph = "login-2",
        variant = "primary",
        onClick = function()
          send({ type = "checkin" })
        end,
      }),
      ui.button({
        text = host.tr("panel.welcome.settings"),
        glyph = "settings",
        variant = "outline",
        onClick = function()
          host.openSettings()
        end,
      }),
    }),
  })
end

-- Hero (spec §7.4.3) ------------------------------------------------------------------

local function heroDetails(live: Live, fmt: Types.DurationFormat): { UiNode }
  if live.targetMs == 0 then
    return { ui.label({ text = host.tr("panel.hero.no_target"), fontSize = DETAIL_SIZE, color = "on_surface_variant" }) }
  end
  local details = {
    ui.label({
      text = host.tr("panel.hero.of_target", { target = Format.duration(live.targetMs, fmt) }),
      fontSize = DETAIL_SIZE,
      color = "on_surface_variant",
    }),
  }
  if live.overtimeMs > 0 then
    table.insert(details, ui.label({
      text = host.tr("panel.hero.over", { overtime = Format.duration(live.overtimeMs, fmt) }),
      fontSize = DETAIL_SIZE,
      color = "tertiary",
    }))
  else
    table.insert(details, ui.label({
      text = host.tr("panel.hero.left", { remaining = Format.duration(live.remainingMs, fmt) }),
      fontSize = DETAIL_SIZE,
      color = "on_surface_variant",
    }))
  end
  return details
end

-- Rough advance width in em of a bold UI font as wide as DejaVu Sans, to keep the
-- counter inside the ring.
local function ems(text: string): number
  local total = 0
  for char in string.gmatch(text, ".") do
    if string.match(char, "%d") then
      total += 0.7
    elseif char == "m" then
      total += 1.05
    elseif string.match(char, "%a") then
      total += 0.72
    else
      total += 0.4
    end
  end
  return total
end

-- The worked time in large numbers with smaller units ("7h 30m"), shrunk when it would
-- not fit inside the ring ("10:30"). Seconds tick discreetly after the colon format only:
-- the other formats are too wide for them.
local function counter(ms: number, fmt: Types.DurationFormat): (UiNode, number)
  local parts = Format.parts(Format.duration(ms, fmt))
  local seconds = fmt == "colon" and string.format(":%02d", ms // 1000 % 60) or nil
  local scaled, labels = 0, #parts
  -- The space between parts follows the unit, at its smaller size.
  local function unitText(index: number): string
    return parts[index].unit .. (index < #parts and " " or "")
  end
  for index, part in parts do
    scaled += ems(part.number) + ems(unitText(index)) * UNIT_SCALE
    labels += if part.unit ~= "" then 1 else 0
  end
  local fixed = 0
  if seconds then
    labels += 1
    fixed += ems(seconds) * SECONDS_SIZE * 0.9 -- regular weight: narrower
  end
  fixed += (labels - 1) * COUNTER_GAP
  local size = math.clamp(math.floor((COUNTER_ROOM - fixed) / scaled), COUNTER_MIN, COUNTER_SIZE)

  -- Labels share the large numbers' baseline: smaller ones stand on a spacer.
  local function small(props)
    local lift = math.round((size - props.fontSize) * BASELINE_RATIO)
    return ui.column({ gap = 0 }, { ui.label(props), ui.box({ height = lift, opacity = 0 }) })
  end
  local nodes = {}
  for index, part in parts do
    table.insert(nodes, ui.label({ text = part.number, fontSize = size, fontWeight = "bold" }))
    if part.unit ~= "" then
      table.insert(nodes, small({ text = unitText(index), fontSize = math.round(size * UNIT_SCALE), fontWeight = "bold" }))
    end
  end
  if seconds then
    table.insert(nodes, small({ text = seconds, fontSize = SECONDS_SIZE, color = "on_surface_variant" }))
  end
  return ui.row({ align = "end", gap = COUNTER_GAP }, nodes), size
end

local function hero(snap: Snapshot, live: Live): UiNode
  local working = snap.status ~= "off"
  local fmt = snap.display.durationFormat
  local count, size = counter(live.workedMs, fmt)
  local details = heroDetails(live, fmt)
  local text = ui.column({ align = "center", gap = 0 }, { count, table.unpack(details) })
  local textHeight = size * 1.25 + #details * DETAIL_SIZE * 1.35

  -- Without a target the ring only frames the counter: an empty track.
  local progress = live.targetMs > 0 and live.workedMs / live.targetMs or 0
  local ringPath = Ring.path(host, HERO_RING, HERO_STROKE, progress, not working)
  local visual
  if ringPath then
    visual = Overlay.center(ui.image({ path = ringPath, width = HERO_RING, height = HERO_RING }), HERO_RING, text, textHeight)
  else
    visual = ui.column({ align = "center", gap = 8 }, {
      text,
      ui.progress({ progress = math.min(progress, 1), width = HERO_RING, height = 6, radius = 3 }),
    })
  end

  local children = { visual }
  table.insert(children, ui.button({
    text = host.tr(working and "panel.checkout" or "panel.checkin"),
    glyph = working and "logout" or "login-2",
    variant = working and "outline" or "primary",
    controlSize = "lg",
    width = 200,
    onClick = function()
      send({ type = working and "checkout" or "checkin" })
    end,
  }))
  return ui.column({ align = "center", gap = HERO_BUTTON_GAP }, children)
end

-- Stat tiles (spec §7.4.4) ------------------------------------------------------------

local function tile(title: string, value: string, valueColor: string?, extra: UiNode?): UiNode
  local children = {
    ui.label({ text = title, fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 16, fontWeight = "bold", color = valueColor }),
  }
  if extra then
    table.insert(children, extra)
  end
  return ui.column({ flexGrow = 1, gap = 4, padding = 12, radius = RADIUS, fill = "surface_variant" }, children)
end

local function stats(snap: Snapshot, live: Live): UiNode
  local fmt = snap.display.durationFormat
  local week = Format.duration(live.weekWorkedMs, fmt)
  local weekProgress
  if live.weekTargetMs > 0 then
    week = week .. " / " .. Format.duration(live.weekTargetMs, fmt)
    weekProgress = ui.progress({ progress = math.min(1, live.weekWorkedMs / live.weekTargetMs), height = 4, radius = 2 })
  end
  local delta = live.workedMs - live.targetMs
  return ui.row({ gap = 8 }, {
    tile(host.tr("panel.stats.week"), week, nil, weekProgress),
    tile(host.tr("panel.stats.today"), Format.signed(delta, fmt), delta >= 60000 and "tertiary" or nil, nil),
  })
end

-- Today (spec §7.4.5) ------------------------------------------------------------------

-- Sessions of the day, the open one ending now.
local function todaySessions(snap: Snapshot, nowS: number): { { startS: number, endS: number, open: boolean } }
  local list = {}
  for _, session in snap.today.sessions do
    table.insert(list, { startS = session.startS, endS = session.endS, open = false })
  end
  if snap.today.openStartMs then
    table.insert(list, { startS = snap.today.openStartMs // 1000, endS = nowS, open = true })
  end
  return list
end

-- Look of each kind of timeline segment (spec §7.4.5). Decided absences are not drawn:
-- kept time is work, removed time is a gap between sessions.
local SEGMENT_STYLES = {
  work = "primary",
  pending = "secondary/0.6",
  gap = "on_surface/0.08",
}

-- Splits the day into segments: gaps, worked time, and the pending absences inside sessions.
local function segmentsOf(sessions, absences, fromS: number, toS: number): { { kind: string, startS: number, endS: number } }
  local segments = {}
  local function push(kind: string, startS: number, endS: number)
    if endS > startS then
      table.insert(segments, { kind = kind, startS = startS, endS = endS })
    end
  end
  local cursor = fromS
  for _, session in sessions do
    push("gap", cursor, session.startS)
    local at = session.startS
    for _, absence in absences do
      local startS, endS = math.max(absence.startS, at), math.min(absence.endS, session.endS)
      if endS > startS then
        push("work", at, startS)
        push("pending", startS, endS)
        at = endS
      end
    end
    push("work", at, session.endS)
    cursor = math.max(cursor, session.endS)
  end
  push("gap", cursor, toS)
  return segments
end

-- Proportional bar from the first whole hour to the next one after now. Widths come from
-- flexGrow, proportional to durations.
local function timeline(sessions, absences, nowS: number): UiNode
  local first = sessions[1].startS
  local fromS = first - (first % 3600)
  local last = math.max(nowS, sessions[#sessions].endS)
  local toS = last - (last % 3600) + 3600
  local segments = {}
  for _, segment in segmentsOf(sessions, absences, fromS, toS) do
    table.insert(segments, ui.box({
      flexGrow = math.max(segment.endS - segment.startS, 60),
      height = 10,
      radius = 3,
      fill = SEGMENT_STYLES[segment.kind],
    }))
  end
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 2 }, segments),
    ui.row({ justify = "space_between" }, {
      ui.label({ text = clock(fromS), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = clock(toS), fontSize = 11, color = "on_surface_variant" }),
    }),
  })
end

local function today(snap: Snapshot, nowS: number): UiNode
  local fmt = snap.display.durationFormat
  local sessions = todaySessions(snap, nowS)
  local children = { ui.label({ text = host.tr("panel.today.title"), fontWeight = "medium" }) }
  if #sessions == 0 then
    table.insert(children, ui.label({ text = host.tr("panel.today.empty"), color = "on_surface_variant", fontSize = 12 }))
    return ui.column({ gap = 8 }, children)
  end
  table.insert(children, timeline(sessions, snap.today.absences, nowS))
  -- Most recent first: the running session stays on top.
  local rows = {}
  for index = #sessions, 1, -1 do
    local session = sessions[index]
    local range = host.tr("panel.today.range", {
      from = clock(session.startS),
      to = session.open and host.tr("panel.today.now") or clock(session.endS),
    })
    table.insert(rows, ui.row({ align = "center", height = ROW_HEIGHT }, {
      ui.label({ text = range, flexGrow = 1, color = session.open and "primary" or nil }),
      ui.label({ text = Format.duration((session.endS - session.startS) * 1000, fmt), fontWeight = "bold" }),
    }))
  end
  table.insert(children, ui.column({ gap = ROW_GAP }, rows))
  return ui.column({ gap = 8 }, children)
end

-- Automation (spec §7.4.6) --------------------------------------------------------------

local function automationSummary(snap: Snapshot): string
  local automation = snap.automation
  if automation.preset == "manual" then
    return host.tr("panel.automation.manual_summary")
  end
  local parts = {
    host.tr("panel.automation.preset." .. automation.preset),
    host.tr("panel.automation.idle", { minutes = automation.idleMin }),
  }
  local window = automation.window
  if window.start ~= window["end"] then
    table.insert(parts, host.tr("panel.automation.window", {
      days = Format.workdays(snap.contract.workdays, dayNames()),
      from = window.start,
      to = window["end"],
    }))
  else
    table.insert(parts, host.tr("panel.automation.no_window"))
  end
  if window.extraRules > 0 then
    table.insert(parts, host.trp("panel.automation.rules", window.extraRules))
  end
  return table.concat(parts, " · ")
end

local function footer(snap: Snapshot): UiNode
  return ui.row({ align = "center", gap = 6 }, {
    ui.label({ text = automationSummary(snap), flexGrow = 1, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    ui.button({
      glyph = detailsOpen and "chevron-down" or "info-circle",
      variant = "ghost",
      controlSize = "sm",
      tooltip = host.tr("panel.automation.details"),
      onClick = function()
        detailsOpen = not detailsOpen
        render()
      end,
    }),
  })
end

local function sectionTitle(text: string): UiNode
  return ui.label({ text = text, fontWeight = "medium" })
end

local function backendRow(glyph: string, name: string, health: Types.BackendHealth): UiNode
  local failing = health == "error" or health == "unavailable"
  return ui.row({ align = "center", gap = 10, height = ROW_HEIGHT }, {
    ui.glyph({ name = glyph, color = "on_surface_variant" }),
    ui.label({ text = host.tr("panel.automation.backend." .. name), flexGrow = 1 }),
    ui.label({ text = host.tr("panel.automation.health." .. health), color = failing and "error" or "on_surface_variant" }),
  })
end

-- 7 × 24 strip of this week's window: one row per day, one cell per hour, filled by the
-- share of the hour inside the window.
local function previewStrip(snap: Snapshot): UiNode
  local names = dayNames()
  local rows = {}
  for day, hours in snap.automation.preview do
    local cells = {}
    for hour = 1, 24 do
      local quarters = tonumber(string.sub(hours, hour, hour)) or 0
      local fill = quarters == 0 and "on_surface/0.08" or string.format("primary/%.2f", quarters / 4)
      table.insert(cells, ui.box({ flexGrow = 1, height = 8, radius = 2, fill = fill }))
    end
    -- Labels take their text's width: a fixed-width column aligns the rows.
    table.insert(rows, ui.row({ align = "center", gap = 6 }, {
      ui.column({ width = PREVIEW_LABEL }, { ui.label({ text = names[day], fontSize = 11, color = "on_surface_variant" }) }),
      ui.row({ flexGrow = 1, gap = 1 }, cells),
    }))
  end
  local ticks = {}
  for _, hour in { "0", "6", "12", "18", "24" } do
    table.insert(ticks, ui.label({ text = hour, fontSize = 10, color = "on_surface_variant" }))
  end
  table.insert(rows, ui.row({ gap = 6 }, {
    ui.column({ width = PREVIEW_LABEL }, {}),
    ui.row({ flexGrow = 1, justify = "space_between" }, ticks),
  }))
  return ui.column({ gap = 3 }, rows)
end

local function errorLine(err: Types.RuleError): string
  local setting
  if err.setting == "extra_rules" then
    setting = host.tr("panel.automation.error_rule", { index = err.index })
  else
    setting = host.tr("settings." .. err.setting .. ".label")
  end
  return host.tr("panel.automation.error_line", {
    setting = setting,
    text = err.text,
    reason = host.tr("panel.automation.reason." .. err.reason),
  })
end

local function automationDetails(snap: Snapshot): { UiNode }
  local automation = snap.automation
  local children = {
    sectionTitle(host.tr("panel.automation.backends")),
    ui.column({ gap = ROW_GAP }, {
      backendRow("keyboard", "idle", automation.backends.idle),
      backendRow("lock", "logind", automation.backends.logind),
    }),
    sectionTitle(host.tr("panel.automation.preview")),
    previewStrip(snap),
  }
  if #automation.ruleErrors > 0 then
    table.insert(children, sectionTitle(host.tr("panel.automation.errors")))
    for _, err in automation.ruleErrors do
      table.insert(children, ui.label({ text = errorLine(err), color = "error", fontSize = 12, maxLines = 3 }))
    end
  end
  table.insert(children, ui.row({ justify = "start" }, {
    ui.button({
      text = host.tr("panel.attention.edit_settings"),
      glyph = "settings",
      variant = "outline",
      onClick = function()
        host.openSettings()
      end,
    }),
  }))
  return children
end

-- Panel ----------------------------------------------------------------------------------

function render()
  if not snapshot then
    panel.render(ui.column({ align = "center", gap = 8, padding = 24 }, {
      ui.glyph({ name = "briefcase-off", size = 32, color = "on_surface_variant" }),
      ui.label({ text = host.tr("panel.waiting"), color = "on_surface_variant" }),
    }))
    return
  end
  local snap = snapshot
  local nowMs = host.nowMs()
  local nowS = nowMs // 1000
  local live = Model.live(snap, nowMs)

  local children = { header(snap, nowS), statusChip(snap, live, nowS) }
  if commandError then
    table.insert(children, ui.label({ text = commandError, color = "error", fontSize = 12 }))
  end

  -- The body scrolls between the fixed status and footer.
  local body
  local cards = {}
  if detailsOpen then
    body = automationDetails(snap)
  else
    cards = attentionCards(snap, nowS)
    body = table.clone(cards)
    if snap.flags.firstRun then
      table.insert(body, welcomeCard(snap))
    end
    table.insert(body, hero(snap, live))
    if not snap.flags.firstRun then
      table.insert(body, stats(snap, live))
    end
    table.insert(body, ui.separator({}))
    table.insert(body, today(snap, nowS))
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 12 }, body))
  table.insert(children, ui.separator({}))
  table.insert(children, footer(snap))

  -- The host does not re-flow siblings, nor resize a scroll, when the tree's structure
  -- changes in an open panel (a card removed, a session added). Keying the root by its
  -- structure makes it build a fresh tree then; per-second updates keep the same key.
  local structure = table.concat({
    tostring(snap.flags.firstRun),
    tostring(commandError ~= nil),
    tostring(detailsOpen),
    tostring(#cards),
    tostring(snap.suggestion),
    tostring(#snap.pending),
    tostring(#snap.automation.ruleErrors),
    tostring(#snap.today.sessions),
    tostring(#snap.today.absences),
    tostring(snap.today.openStartMs ~= nil),
  }, "|")
  panel.render(ui.column({ key = structure, gap = 12, flexGrow = 1 }, children))
end

host.state.watch("shift.snapshot", function(value)
  snapshot = value
  if isOpen then
    render()
  end
end)

function onOpen()
  isOpen = true
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  commandError = nil
  detailsOpen = false
end

function update()
  sender.tick()
  if isOpen then
    render()
  end
end

function onKey(chord, pressed)
  if chord == "ctrl+z" and pressed and snapshot and snapshot.undo then
    send({ type = "undo", id = snapshot.undo.id })
  end
end
