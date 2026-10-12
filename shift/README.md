# Shift

Track your working hours from the Noctalia shell: one-click check in / check out, a live daily counter against your
contract, and an overtime balance you can adjust. Automation can suggest or do check-ins within your work hours, and
asks what to do with the time you were away. Shift is under active development: history and the balance are coming.

## Plugin

| Field | Value |
| --- | --- |
| ID | `hbollon/shift` |
| Entries | Service: `core`; bar widget: `bar`; panel: `dashboard`; shortcut: `tile` |

## Requirements

- `swayidle` (optional): detects when you are away from the keyboard. Without it, Shift still follows the session lock
  and system sleep, and shows a hint in the dashboard.
- `gdbus` (from GLib, `libglib2.0-bin` on Debian and Ubuntu) and systemd-logind: lock and sleep detection. Without
  `gdbus`, Shift polls `loginctl` for the lock state.

## Usage

- **Bar widget**: add `Shift` from the bar's Add-widget picker (or configure a widget with
  `type = "hbollon/shift:bar"`). It shows your status, today's worked time and a progress ring toward your daily
  target; hover it for the details.
  - Left click: open the dashboard.
  - Right click: check in, or check out when working.
- **Dashboard panel**: today's counter and target, the check in / check out button, this week's total and today's
  sessions. Cards at the top ask about absences and suggestions; the footer summarises automation, and its details
  show the signal sources and this week's work hours. Recent actions can be undone for 10 minutes (header button or
  `Ctrl+Z`). It opens from the bar widget or the control-center tile, or with:

  ```sh
  noctalia msg panel-toggle hbollon/shift:dashboard
  ```

- **Control-center tile**: add `Shift` from Settings → Control Center shortcuts. Click it to check in or out;
  right-click it to open the dashboard.
- **IPC**, for keybinds and scripts:

  ```sh
  noctalia msg plugin hbollon/shift:core all checkin
  noctalia msg plugin hbollon/shift:core all checkout
  noctalia msg plugin hbollon/shift:core all toggle
  noctalia msg plugin hbollon/shift:core all undo
  noctalia msg plugin hbollon/shift:core all resolve keep     # or remove: the oldest absence to review
  noctalia msg plugin hbollon/shift:core all signal idle      # idle, active, lock, unlock, sleep, resume
  ```

### Automation

Automation acts only within your work hours (the window), on your workdays:

- **Check in / check out**: with the *Assisted* preset, Shift suggests checking in when you start using your computer
  within your work hours, and checking out when they end. *Automatic* does it for you. A manual check-out holds
  automatic check-ins until the end of the current work-hours period; a session started outside your work hours is
  never closed by them.
- **Absences**: when you come back after being inactive, with the screen locked or the computer asleep for at least
  15 minutes, Shift asks whether that time was work (a meeting, a call) or should be removed. Shorter breaks count as
  work.
- **End of day**: a session still open when the workday ends (at 04:00 by default) is closed at your last activity,
  and unreviewed absences count as work.

Additional rules add or remove time from the work hours, one per line: `+` or `-`, then `*`, days (`mon-fri`,
`sat,sun`), a date (`2026-12-24`) or a date range (`2026-12-24..2027-01-02`), and an optional time range:

```text
- * 12:00-13:30        lunch break
- fri 16:00-24:00      short Fridays
+ sat 09:00-12:00      Saturday mornings
```

With `Idle detection` set to External, send the idle signals yourself, for example from hypridle:

```ini
listener {
  timeout = 300
  on-timeout = noctalia msg plugin hbollon/shift:core all signal idle
  on-resume  = noctalia msg plugin hbollon/shift:core all signal active
}
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Weekly hours | 35 | Contract hours per week, split evenly over your workdays (35 h over Monday–Friday is 7:00 a day). |
| Work week | Monday to Friday | Your workdays: Monday–Friday, Monday–Saturday, or a custom set of days. |
| Workday starts at | 4 | Advanced. Hour at which a new workday begins; work after midnight and before it counts toward the previous day. |
| Duration format | 7:30 | How durations are displayed: `7:30`, `7h 30m` or `7.50 h`. |
| Automation | Assisted | Manual, Assisted (suggests check-ins and check-outs, asks about absences), Automatic (checks in and out for you, asks about absences) or Custom. |
| Work hours start / end | 08:00 / 19:00 | The automation window on your workdays (`24:00` allowed as the end). |
| Not on public holidays | On | Public holidays are outside the work hours (holidays are not fetched yet). |
| Additional rules | none | Rules that add or remove time from the work hours (see Automation above). |
| Check in / Check out | Suggest | Custom only: off, suggest, or automatically. |
| When inactive / locked / asleep or offline | Ask me | Custom only: count it as work, ask me, remove it, or check out. |
| Inactive after (minutes) | 5 | Minutes without input before you count as away. |
| Shortest absence (minutes) | 15 | Shorter breaks count as work. |
| Unreviewed absences | Count them as work | Advanced. What happens at the end of the day to absences you did not review. |
| Idle detection | Auto | Advanced. Auto (swayidle when installed), swayidle, External (IPC) or Off. |

Each bar widget also has its own settings (middle-click the widget to open them):

| Setting | Default | Description |
| --- | --- | --- |
| Style | Icon, time and progress ring | Or icon and time, or time only. The ring is hidden on days without a target. |
| Value | Worked today | Or the time remaining today (overtime shows as `+0:23`). |
| When checked out | Dim | Show normally, dim, or hide the widget until the next check-in. |

## Notes

The `core` service starts automatically when the plugin is enabled. Shift stores its data as JSON files in
`~/.local/state/noctalia/plugins/data/hbollon/shift/` (`state.json`, `balance.json` and one `ledger/<year>.json` per
year), plus generated progress-ring images in `cache/`. Disabling or removing the plugin never deletes them.

Shift does not access the network yet. Unless automation is set to Manual, the service runs these processes:

- `swayidle -w timeout <minutes × 60> 'echo idle' resume 'echo active'`, for idle detection;
- `gdbus monitor --system --dest org.freedesktop.login1`, and `gdbus call` once at startup to find the session and its
  lock state; or `loginctl show-session <id> -p LockedHint` every 15 s when `gdbus` is missing;
- `/bin/sh -c 'kill -TERM -- -<pid>'` to stop swayidle when its settings change.

Noctalia stops them when the plugin is disabled or reloaded.
