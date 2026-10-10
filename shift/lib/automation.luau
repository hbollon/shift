--!nonstrict
-- The automation reducer (spec §9.2): every user command, IPC call, signal and tick
-- becomes an event for one pure function
--
--   reduce(state, event, ctx) -> state', effects, result
--
-- `state` mirrors state.json and is never mutated. `effects` are applied by the service
-- in order (ledger writes before the state, persistence before publishing, spec §10.3):
--
--   { type = "ledger.addSession", date = "YYYY-MM-DD", session = { id, startS, endS, origin } }
--   { type = "ledger.removeSession", date = "YYYY-MM-DD", id = "s_…" }
--   { type = "state.save" }
--   { type = "publish" }
--
-- `result` is `{ ok = true, changed = bool }` or `{ ok = false, error = code }`. Commands
-- are idempotent: a check-in while working is accepted and changes nothing, so a command
-- delivered twice is harmless (spec §9.3).
--
--   ctx = { nowS, settings }
--
-- Events so far: manual tracking (spec §6.2: checkin, checkout, toggle), undo (§6.8.4)
-- and the dismissal of the first-run card (§6.10).

local Model = require("./model.luau")
local Time = require("./time.luau")
local Types = require("./types.luau")

type State = Types.State
type Event = Types.Event
type Effect = Types.Effect
type Result = Types.Result
type ReduceContext = Types.ReduceContext
type UndoEntry = Types.UndoEntry
type Handler = (state: State, event: Event, ctx: ReduceContext) -> (State, { Effect }, Result)

local Automation = {}

local UNCHANGED: Result = { ok = true, changed = false }
local CHANGED: Result = { ok = true, changed = true }

-- Pushes an undo entry onto a state copy, keeping at most UNDO_DEPTH entries.
local function pushUndo(state: State, entry: UndoEntry)
  local stack = table.clone(state.undo or {})
  table.insert(stack, entry)
  while #stack > Model.UNDO_DEPTH do
    table.remove(stack, 1)
  end
  state.undo = stack
end

local function saveAndPublish(effects: { Effect }): { Effect }
  table.insert(effects, { type = "state.save" })
  table.insert(effects, { type = "publish" })
  return effects
end

local handlers: { [string]: Handler } = {}

function handlers.checkin(state, event, ctx)
  if state.open then
    return state, {}, UNCHANGED
  end
  local next = table.clone(state)
  local open = { id = Model.sessionId(ctx.nowS), startS = ctx.nowS, origin = event.origin or "manual" }
  next.open = open
  next.firstRunDismissed = true
  pushUndo(next, { id = "checkin:" .. open.id, action = "checkin", atS = ctx.nowS, session = open })
  return next, saveAndPublish({}), CHANGED
end

function handlers.checkout(state, _event, ctx)
  local open = state.open
  if not open then
    return state, {}, UNCHANGED
  end
  local effects: { Effect } = {}
  local session = { id = open.id, startS = open.startS, endS = ctx.nowS, origin = open.origin }
  local date = Time.workdayOf(open.startS, ctx.settings.dayStartHour)
  -- A check-out in the same second as the check-in leaves nothing worth recording.
  local recorded = ctx.nowS > open.startS
  if recorded then
    table.insert(effects, { type = "ledger.addSession", date = date, session = session })
  end
  local next = table.clone(state)
  next.open = nil
  pushUndo(next, {
    id = "checkout:" .. open.id,
    action = "checkout",
    atS = ctx.nowS,
    session = session,
    date = date,
    recorded = recorded,
  })
  return next, saveAndPublish(effects), CHANGED
end

function handlers.toggle(state, event, ctx)
  if state.open then
    return handlers.checkout(state, event, ctx)
  end
  return handlers.checkin(state, event, ctx)
end

-- Reverts the most recent action if it is younger than the undo window. `event.id`
-- (sent by the UIs) must name that action: an undo delivered twice then finds another
-- entry on top, or none, and does nothing. IPC sends no id and undoes the top entry.
function handlers.undo(state, event, ctx)
  local top = Model.undoable(state, ctx.nowS)
  if not top then
    if event.id then
      return state, {}, UNCHANGED
    end
    return state, {}, { ok = false, error = "nothing_to_undo" }
  end
  if event.id and event.id ~= top.id then
    return state, {}, UNCHANGED
  end

  local next = table.clone(state)
  local stack = table.clone(state.undo :: { UndoEntry })
  table.remove(stack)
  next.undo = stack
  local effects: { Effect } = {}
  if top.action == "checkin" then
    -- The stack is in action order, so the session it opened is still the open one.
    if not (state.open and state.open.id == top.session.id) then
      return state, {}, { ok = false, error = "undo_conflict" }
    end
    next.open = nil
  else
    if state.open then
      return state, {}, { ok = false, error = "undo_conflict" }
    end
    if top.recorded then
      table.insert(effects, { type = "ledger.removeSession", date = top.date, id = top.session.id })
    end
    next.open = { id = top.session.id, startS = top.session.startS, origin = top.session.origin }
  end
  return next, saveAndPublish(effects), CHANGED
end

handlers["onboarding.dismiss"] = function(state, _event, _ctx)
  if state.firstRunDismissed then
    return state, {}, UNCHANGED
  end
  local next = table.clone(state)
  next.firstRunDismissed = true
  return next, saveAndPublish({}), CHANGED
end

function Automation.reduce(state: State, event: Event, ctx: ReduceContext): (State, { Effect }, Result)
  local handler = handlers[event.type]
  if not handler then
    return state, {}, { ok = false, error = "unknown_command" }
  end
  return handler(state, event, ctx)
end

return Automation
