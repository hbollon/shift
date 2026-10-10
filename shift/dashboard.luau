--!nonstrict
-- Shift dashboard panel (spec §7.4): header with undo, status, first-run card, hero ring
-- with the live counter and the check in/out button, stat tiles, and today's timeline.
-- It renders the core snapshot every second while open and sends actions as commands.

local Commands = require("./lib/commands.luau")
local Format = require("./lib/format.luau")
local Host = require("./lib/host.luau")
local Model = require("./lib/model.luau")
local Overlay = require("./lib/ui/overlay.luau")
local Ring = require("./lib/ring.luau")
local Types = require("./lib/types.luau")

type Snapshot = Types.Snapshot
type Live = Types.Live

local HERO_RING = 148
local HERO_STROKE = 11
local COUNTER_SIZE = 36
local DETAIL_SIZE = 13
local RADIUS = 12
-- Session list: fixed row height so the list can be sized explicitly; past MAX_ROWS it
-- scrolls, keeping room for the rest of the panel.
local ROW_HEIGHT = 22
local ROW_GAP = 6
local MAX_ROWS = 5
local SCROLL_PADDING = 8

local host = Host.new()
local snapshot: Snapshot? = host.state.get("shift.snapshot")
local isOpen = false
local commandError: string? = nil -- shown inline until the next action

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
  return host.tr("panel.undo." .. undo.action, { time = clock(undo.atS) })
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

-- Status chip, with the estimated end of the day on the right while working.
local function statusChip(snap: Snapshot, live: Live): UiNode
  local working = snap.status == "working"
  local text
  if working and snap.since then
    text = host.tr("panel.status.working_since", { time = clock(snap.since) })
  elseif snap.since then
    text = host.tr("panel.status.off_since", { time = clock(snap.since) })
  else
    text = host.tr("panel.status.off")
  end
  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 8, paddingH = 10, paddingV = 4, radius = 999, fill = "surface_variant" }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = working and "primary" or "on_surface_variant" }),
      ui.label({ text = text, fontSize = 12 }),
    }),
    ui.label({
      text = live.etaS and host.tr("panel.hero.done_at", { time = clock(live.etaS) }) or "",
      fontSize = 12,
      color = "on_surface_variant",
    }),
  })
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

local function hero(snap: Snapshot, live: Live): UiNode
  local working = snap.status == "working"
  local fmt = snap.display.durationFormat
  -- Discreet seconds, written to match the duration format ("5:42:17", "5h 42m 17s").
  local counterParts = { ui.label({ text = Format.duration(live.workedMs, fmt), fontSize = COUNTER_SIZE, fontWeight = "bold" }) }
  local seconds = live.workedMs // 1000 % 60
  if fmt ~= "decimal" then
    table.insert(counterParts, ui.label({
      text = string.format(fmt == "units" and " %02ds" or ":%02d", seconds),
      fontSize = 16,
      color = "on_surface_variant",
    }))
  end
  local counter = ui.row({ align = "end", gap = 2 }, counterParts)
  local details = heroDetails(live, fmt)
  local text = ui.column({ align = "center", gap = 0 }, { counter, table.unpack(details) })
  local textHeight = COUNTER_SIZE * 1.25 + #details * DETAIL_SIZE * 1.35

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
  return ui.column({ align = "center", gap = 8 }, children)
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

-- Proportional bar from the first whole hour to the next one after now: sessions in
-- primary, gaps faint. Widths come from flexGrow, proportional to durations.
local function timeline(sessions, nowS: number): UiNode
  local first = sessions[1].startS
  local fromS = first - (first % 3600)
  local last = math.max(nowS, sessions[#sessions].endS)
  local toS = last - (last % 3600) + 3600
  local segments = {}
  local cursor = fromS
  for _, session in sessions do
    if session.startS > cursor then
      table.insert(segments, ui.box({ flexGrow = session.startS - cursor, height = 10, radius = 3, fill = "on_surface/0.08" }))
    end
    table.insert(segments, ui.box({ flexGrow = math.max(session.endS - session.startS, 60), height = 10, radius = 3, fill = "primary" }))
    cursor = session.endS
  end
  if toS > cursor then
    table.insert(segments, ui.box({ flexGrow = toS - cursor, height = 10, radius = 3, fill = "on_surface/0.08" }))
  end
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 2 }, segments),
    ui.row({ justify = "space_between" }, {
      ui.label({ text = clock(fromS), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = clock(toS), fontSize = 11, color = "on_surface_variant" }),
    }),
  })
end

-- Title and timeline stay in place; only the list of sessions scrolls when long.
local function today(snap: Snapshot, nowS: number): UiNode
  local fmt = snap.display.durationFormat
  local sessions = todaySessions(snap, nowS)
  local children = { ui.label({ text = host.tr("panel.today.title"), fontWeight = "medium" }) }
  if #sessions == 0 then
    table.insert(children, ui.label({ text = host.tr("panel.today.empty"), color = "on_surface_variant", fontSize = 12 }))
    return ui.column({ gap = 8 }, children)
  end
  table.insert(children, timeline(sessions, nowS))
  -- Most recent first, so the running session stays visible when the list scrolls.
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
  if #rows <= MAX_ROWS then
    table.insert(children, ui.column({ gap = ROW_GAP }, rows))
  else
    -- Five full rows and half of the next, which tells there is more. ui.scroll ignores
    -- `height` and pads its content: a fixed-height column holds it and it fills the column.
    local height = MAX_ROWS * (ROW_HEIGHT + ROW_GAP) + ROW_HEIGHT / 2 + SCROLL_PADDING
    table.insert(children, ui.column({ height = height }, { ui.scroll({ flexGrow = 1, gap = ROW_GAP }, rows) }))
  end
  return ui.column({ gap = 8 }, children)
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

  local children = { header(snap, nowS), statusChip(snap, live) }
  if commandError then
    table.insert(children, ui.label({ text = commandError, color = "error", fontSize = 12 }))
  end
  if snap.flags.firstRun then
    table.insert(children, welcomeCard(snap))
  end
  table.insert(children, hero(snap, live))
  if not snap.flags.firstRun then
    table.insert(children, stats(snap, live))
  end
  table.insert(children, ui.separator({}))
  table.insert(children, today(snap, nowS))

  -- The host does not re-flow siblings, nor resize a scroll, when the tree's structure
  -- changes in an open panel (a card removed, a session added). Keying the root by its
  -- structure makes it build a fresh tree then; per-second updates keep the same key.
  local structure = table.concat({
    tostring(snap.flags.firstRun),
    tostring(commandError ~= nil),
    tostring(#snap.today.sessions),
    tostring(snap.today.openStartMs ~= nil),
  }, "|")
  panel.render(ui.column({ key = structure, gap = 12 }, children))
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
