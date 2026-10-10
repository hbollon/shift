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
--   { type = "state.save" }
--   { type = "publish" }
--
-- `result` is `{ ok = true, changed = bool }` or `{ ok = false, error = code }`. Commands
-- are idempotent: a check-in while working is accepted and changes nothing, so a command
-- delivered twice is harmless (spec §9.3).
--
--   ctx = { nowS, settings }
--
-- Only manual tracking exists so far (spec §6.2): checkin, checkout and toggle.

local Model = require("./model.luau")
local Time = require("./time.luau")
local Types = require("./types.luau")

type State = Types.State
type Event = Types.Event
type Effect = Types.Effect
type Result = Types.Result
type ReduceContext = Types.ReduceContext
type Handler = (state: State, event: Event, ctx: ReduceContext) -> (State, { Effect }, Result)

local Automation = {}

local UNCHANGED: Result = { ok = true, changed = false }

local handlers: { [string]: Handler } = {}

function handlers.checkin(state, event, ctx)
  if state.open then
    return state, {}, UNCHANGED
  end
  local next = table.clone(state)
  next.open = { id = Model.sessionId(ctx.nowS), startS = ctx.nowS, origin = event.origin or "manual" }
  return next, { { type = "state.save" }, { type = "publish" } }, { ok = true, changed = true }
end

function handlers.checkout(state, _event, ctx)
  local open = state.open
  if not open then
    return state, {}, UNCHANGED
  end
  local effects: { Effect } = {}
  -- A check-out in the same second as the check-in leaves nothing worth recording.
  if ctx.nowS > open.startS then
    table.insert(effects, {
      type = "ledger.addSession",
      date = Time.workdayOf(open.startS, ctx.settings.dayStartHour),
      session = { id = open.id, startS = open.startS, endS = ctx.nowS, origin = open.origin },
    })
  end
  table.insert(effects, { type = "state.save" })
  table.insert(effects, { type = "publish" })
  local next = table.clone(state)
  next.open = nil
  return next, effects, { ok = true, changed = true }
end

function handlers.toggle(state, event, ctx)
  if state.open then
    return handlers.checkout(state, event, ctx)
  end
  return handlers.checkin(state, event, ctx)
end

function Automation.reduce(state: State, event: Event, ctx: ReduceContext): (State, { Effect }, Result)
  local handler = handlers[event.type]
  if not handler then
    return state, {}, { ok = false, error = "unknown_command" }
  end
  return handler(state, event, ctx)
end

return Automation
