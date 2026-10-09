# S1 — Idle detection with swayidle through `runStream`

| | |
|---|---|
| **Spec** | 0001 §5.2 C1, §6.3.2, §16 S1 |
| **Date** | 2026-10-09 |
| **Environment** | Noctalia 5.2.1 · Hyprland · swayidle 1.9.0 |
| **Verdict** | ✅ **GO** — plain command string, no wrapper needed |

## Question

Do the stdout lines of commands run *by* swayidle (`echo idle` / `echo active`) reach the plugin's `onLine`
callback, and is swayidle terminated with the plugin runtime (no orphans)?

## Method

`spikes/shift-spike/core.luau` runs
`swayidle -w timeout <T> 'echo idle' resume 'echo active'` with `noctalia.runStream` (T = 5 s for the spike), then
the user stayed away from the machine. The service was hot-reloaded afterwards (`touch core.luau`) while checking
`pgrep swayidle`.

## Results

| Observation | Result |
|-------------|--------|
| `runStream` accepted, process tree | ✅ `sh -c` execs straight into `swayidle` (single command), one process |
| `idle` line | ✅ delivered at exactly `start + T` (19:24:48.479 → 19:24:53.484) |
| `active` line | ✅ delivered on the first input after 18 min away (19:43:05) |
| Noctalia idle lock while swayidle idle | swayidle stays idle across Noctalia's own 300 s idle lock (19:29:49) — the two clients are independent |
| Input on the lock screen | ⚠️ `active` fires on the **first key press on the lock screen**, before the password is accepted |
| Hot reload (`onExit` reason `reload`) | ✅ swayidle and the gdbus monitors are killed by the host — no orphans |
| `exec` wrapper variant | not needed |

A spurious-looking `idle` → `active` pair 170 ms apart was observed while the user typed their password
(19:43:09.683 / 19:43:09.854): swayidle's timer had kept running from the earlier input burst. Short flaps like this
are harmless because absences below `min_absence_min` are discarded.

## Decisions for implementation

1. Run `swayidle -w timeout <idle_timeout_s> 'echo idle' resume 'echo active'` in string form; `<idle_timeout_s>` is a
   validated integer from settings (no other interpolation). Restart the stream only when the timeout or backend
   setting changes.
2. Absence start for an `idle` line = receipt time − timeout (§6.3.2, confirmed accurate to the millisecond).
3. **While the session is locked, `active` does not end an absence** — only `unlock` (or `resume` + unlock) does.
   Otherwise typing the password would end the absence a few seconds early and, worse, could trigger auto check-in
   on the lock screen. The reducer treats `active` as an activity signal only when `locked == false`.
4. Debounce `active` → `idle` flaps shorter than 2 s (keep the earlier idle start).
5. Stream closure (swayidle crash or missing compositor protocol) → restart with backoff (max 5/min), then mark the
   idle backend `error` (§12 E13). Since `runStream` does not surface stderr, start-up failures are detected by the
   stream closing within 2 s.

## Spec impact

- §6.3.2 / §6.3.4: add rule 3 above (activity while locked does not count).
