# S5 — State channel throughput and `watch` semantics

| | |
|---|---|
| **Spec** | 0001 §9.3, §9.4, §16 S5 |
| **Date** | 2026-10-09 |
| **Environment** | Noctalia 5.2.1 (`plugin_api` 32) |
| **Verdict** | ✅ **GO** for snapshots · ⚠️ **GO with a change** for commands (acknowledgement + retry) |

## Question

Is `noctalia.state` cheap enough for the snapshot design, and can it carry UI → service commands reliably?

## Method

`spikes/shift-spike`: the service publishes the §9.3 snapshot shape (`bench N`), the bar widget counts receipts;
identical values are set twice (`same`); the bar sends two identical commands back-to-back (`cmd`). Delivery
mechanics were then read in `src/scripting/script_runtime.cpp`.

## Results

| Measure | Result |
|---------|--------|
| Snapshot size (§9.3 shape, JSON) | 786 bytes |
| `state.set` cost in the publisher | ~0.01 ms per set (1000 sets in 9 ms) |
| Publish → watcher latency (other VM) | < 1 ms for a single set; last of 1000 delivered 10 ms after the first |
| Identical value set twice (table and string) | `watch` fires **twice** — no deduplication |
| Two identical commands back-to-back | both delivered, latency 0 ms |
| Burst of 1000 sets | watcher received **792** — 208 dropped, the last one always delivered |

**Why drops happen.** Each entry VM has an event queue bounded at `kMaxQueuedEvents = 64`. When it is full, a new
non-droppable event (state-watch results, stream lines, async results) is rejected unless an `Update` tick or a
droppable event can be evicted. State-watch results are *not* coalesced: they are simply lost when the receiver is
saturated.

## Decisions for implementation

1. **Snapshots** keep the spec design (publish on change + once per minute). Losing an intermediate snapshot is
   harmless because each one is complete and the latest is always delivered when traffic is low. Never publish in
   tight loops; batch mutations and publish once per handled event.
2. **Commands** (`shift.cmd`) must survive a dropped event:
   - every command carries a unique `seq` (per sender) and a `from` entry id;
   - the service publishes `shift.ack` = `{ [from] = lastProcessedSeq }` after handling, and processes a given
     `(from, seq)` at most once (idempotency);
   - the sender keeps unacknowledged commands and re-sends after 1 s (max 5 attempts, then shows an inline error).
3. `seq` is **not** needed to make identical commands fire (watch has no dedup), but it remains required for
   acknowledgement and idempotency.
4. Keep the service's own queue shallow: stream parsers (gdbus, swayidle) must filter early and never call
   `state.set` per raw line.

## Spec impact

- §9.3: replace "monotonically increasing `seq`, so identical consecutive commands still trigger `watch`" with the
  ack/retry/idempotency protocol above, and add the `shift.ack` key.
