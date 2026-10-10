# Shift

Track your working hours from the Noctalia shell: one-click check in / check out, a live daily counter against your
contract, and an overtime balance you can adjust. Shift is under active development: manual check in / check out and
the bar widget work today; the dashboard and automation are coming.

## Plugin

| Field | Value |
| --- | --- |
| ID | `hbollon/shift` |
| Entries | Service: `core`; bar widget: `bar`; panel: `dashboard`; shortcut: `tile` |

## Usage

- **Bar widget**: add `Shift` from the bar's Add-widget picker (or configure a widget with
  `type = "hbollon/shift:bar"`). It shows your status, today's worked time and a progress ring toward your daily
  target; hover it for the details.
  - Left click: open the dashboard.
  - Right click: check in, or check out when working.
- **Dashboard panel**: opens from the bar widget or the control-center tile, or with:

  ```sh
  noctalia msg panel-toggle hbollon/shift:dashboard
  ```

- **Control-center tile**: add `Shift` from Settings → Control Center shortcuts.
- **IPC**, for keybinds and scripts:

  ```sh
  noctalia msg plugin hbollon/shift:core all checkin
  noctalia msg plugin hbollon/shift:core all checkout
  noctalia msg plugin hbollon/shift:core all toggle
  noctalia msg plugin hbollon/shift:core all undo
  ```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Weekly hours | 35 | Contract hours per week, split evenly over your workdays (35 h over Monday–Friday is 7:00 a day). |
| Work week | Monday to Friday | Your workdays: Monday–Friday, Monday–Saturday, or a custom set of days. |
| Workday starts at | 4 | Advanced. Hour at which a new workday begins; work after midnight and before it counts toward the previous day. |
| Duration format | 7:30 | How durations are displayed: `7:30`, `7h 30m` or `7.50 h`. |

Each bar widget also has its own settings (middle-click the widget to open them):

| Setting | Default | Description |
| --- | --- | --- |
| Style | Icon, time and progress ring | Or icon and time, or time only. The ring is hidden on days without a target. |
| Value | Worked today | Or the time remaining today (overtime shows as `+0:23`). |
| When checked out | Dim | Show normally, dim, or hide the widget until the next check-in. |

## Notes

The `core` service starts automatically when the plugin is enabled. Shift stores its data as JSON files in
`~/.local/state/noctalia/plugins/data/hbollon/shift/` (`state.json`, `balance.json` and one `ledger/<year>.json` per
year), plus generated progress-ring images in `cache/`. Disabling or removing the plugin never deletes them. Shift does not access the network or spawn processes yet.
