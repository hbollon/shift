# S2 — logind monitoring (lock / unlock / sleep)

| | |
|---|---|
| **Spec** | 0001 §5.2 C3, §6.3.2, §16 S2 |
| **Date** | 2026-10-09 |
| **Environment** | Noctalia 5.2.1 · Hyprland · CachyOS (systemd 25x) · glib2 `gdbus` |
| **Verdict** | ✅ **GO** — `gdbus monitor` via `runStream`, session path from `GetSession("auto")` |

## Question

Can the service reliably observe session lock/unlock and suspend/resume without Noctalia exposing them to plugins,
and without extra dependencies?

## Method

Spike plugin `spikes/shift-spike` (`core.luau`), driven over IPC:

1. Resolve our logind session object path three ways.
2. Start three monitor variants in parallel with `noctalia.runStream`: `gdbus monitor`, `stdbuf -oL gdbus monitor`,
   `busctl monitor`.
3. Flip `LockedHint` without locking the screen (`Session.SetLockedHint true/false` via `gdbus call`), then observe a
   **real Noctalia lock** (the user locked the session during the spike).
4. Time a `loginctl show-session` poll (fallback).

## Results

**Session resolution**

| Method | Result |
|--------|--------|
| `Manager.GetSession("$XDG_SESSION_ID")` | ✅ `/org/freedesktop/login1/session/_32` (`XDG_SESSION_ID=2` is visible to plugins via `noctalia.getenv`) |
| `Manager.GetSession("auto")` | ✅ same path — the `gdbus` child process belongs to the user session |
| `Manager.GetSessionByPID($PPID)` (Noctalia's PID) | ❌ `NoSessionForPID` — Noctalia runs in a scope outside the logind session on this setup |

**Monitors**

| Variant | Result |
|---------|--------|
| `gdbus monitor --system --dest org.freedesktop.login1` | ✅ lines arrive immediately (gdbus flushes per line; no `stdbuf` needed) |
| `stdbuf -oL gdbus monitor …` | ✅ identical, no benefit |
| `busctl monitor --system …` | ❌ `BecomeMonitor failed: Access denied` (needs privileges); silent through `runStream` because stderr is not streamed |

Observed lines (exact format):

```
/org/freedesktop/login1/session/_32: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'LockedHint': <true>}, @as [])
/org/freedesktop/login1/session/_32: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'LockedHint': <false>}, @as [])
```

The first line was also received at 19:15:19 when **Noctalia's own lock screen engaged**, confirming that Noctalia
sets `LockedHint` (as read in `src/dbus/logind/logind_service.cpp`).

`PrepareForSleep` was not triggered (suspending the workstation during the spike was not desirable). Its format is
the standard gdbus signal rendering, `/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)`,
and the same monitor stream carries it. It is covered by the clock-gap detector regardless (§6.3.2), and will be
verified live during M4 ("live tests on suspend").

**Fallback poll:** `loginctl show-session 2 -p LockedHint -p IdleHint` takes ~3 ms; `IdleHint` stays `no` on Hyprland
(not usable as an idle source).

## Decisions for implementation

1. Resolve the session path with `GetSession(XDG_SESSION_ID)`, falling back to `GetSession("auto")`.
2. Run `gdbus monitor --system --dest org.freedesktop.login1` (string form, constant command) through `runStream`.
3. Parse only two line shapes, anchored on our session path / the Manager path:
   - `^<sessionPath>: org%.freedesktop%.DBus%.Properties%.PropertiesChanged %('org%.freedesktop%.login1%.Session', {.-'LockedHint': <(%a+)>`
   - `^/org/freedesktop/login1: org%.freedesktop%.login1%.Manager%.PrepareForSleep %((%a+),%)`
   Other properties may appear in the same dict; the pattern must not assume `LockedHint` is the only key.
4. On startup, read the initial `LockedHint` once with `loginctl show-session <id> -p LockedHint` (the monitor only
   reports changes).
5. If `gdbus` is missing or the stream closes, fall back to polling `loginctl` every 15 s; report backend health as
   `logind = "poll"`.
6. Drop `busctl` from the spec's fallback list.
7. Distribution note: on Debian/Ubuntu `gdbus` ships in `libglib2.0-bin`; README will mention it.

## Spec impact

- §16 S2 fallback: replace "`busctl monitor`" with "`loginctl` polling" (busctl needs monitor privileges).
