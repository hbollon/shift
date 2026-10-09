--!nonstrict
-- Shift core service: the single source of truth of the plugin. It will own the
-- tracking state machine, system signals and persistence, and publish a snapshot
-- that every UI entry renders (spec §9).
--
-- For now it only publishes an initial "off" snapshot so the UI entries have
-- something to render.

noctalia.state.set("shift.snapshot", {
  v = 1,
  status = "off",
})
