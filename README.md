# Shift

**Track your working hours from your Noctalia desktop.** One-click check in / check out, a live daily counter against
your contract, smart and fully configurable automation (activity, session lock, sleep, schedule), and an overtime
balance you can adjust when you take time off — all rendered with Noctalia's native controls and your theme.

> **Status: early development.** Tracking works from the bar widget, the dashboard, the control-center tile and IPC,
> with automation (presets, work-hours window, idle, lock and sleep detection, absences to review); history and the
> overtime balance are being built.
> See the [specification](docs/specs/0001-shift-v1.md) for what v1 will do.

## Highlights (v1)

- **Bar widget** with your status, today's worked time and a small progress ring; right-click to check in or out.
- **Dashboard panel**: live counter with estimated end time, week and balance at a glance, history (week/month),
  per-day editing, balance adjustments, undo.
- **Control-center tile** to toggle tracking.
- **Automation you stay in control of**: manual / assisted / automatic presets, idle and lock detection, a schedule
  window with exceptions, and "were you working?" prompts instead of silently dropped time.
- **Overtime balance** from weekly hours split over your workdays, public holidays per country, days off and manual
  adjustments.
- **Theme-native**: palette roles only, light and dark, no hard-coded colors.

## Requirements

- [Noctalia](https://github.com/noctalia-dev/noctalia) **5.2.0 or newer** (plugin API 32).
- Optional: [`swayidle`](https://github.com/swaywm/swayidle) for idle detection.
- `gdbus` (GLib) for session lock and sleep detection; it ships with Noctalia's dependencies on most distributions
  (`libglib2.0-bin` on Debian/Ubuntu).

## Installation

Shift will be published in the Noctalia plugin store. Until then, add this repository as a plugin source:

```sh
noctalia msg plugins source add shift git https://github.com/hbollon/shift
noctalia msg plugins enable hbollon/shift
```

Then add the **Shift** widget to a bar and the **Shift** shortcut to the control center from Noctalia's settings.

## Documentation

- [Specification](docs/specs/0001-shift-v1.md) — behavior, UX, architecture and decisions.
- [Technical spikes](docs/spikes/README.md) — platform validation behind the design.
- [Plugin page](shift/README.md) — entries, usage and settings as shown in the plugin store.
- [Contributing](CONTRIBUTING.md) — development setup, tests and conventions.

## License

[MIT](LICENSE) © Hugo Bollon
