# Shift

Track your working hours from the Noctalia shell: one-click check in / check out, a live daily counter against your
contract, and an overtime balance you can adjust. Shift is under active development: manual check in / check out
works today over IPC; the bar widget, dashboard and automation are coming.

## Plugin

| Field | Value |
| --- | --- |
| ID | `hbollon/shift` |
| Entries | Service: `core`; bar widget: `bar`; panel: `dashboard`; shortcut: `tile` |

## Usage

- **Bar widget**: add `Shift` from the bar's Add-widget picker (or configure a widget with
  `type = "hbollon/shift:bar"`). Click it to open the dashboard.
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
  ```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Weekly hours | 35 | Contract hours per week, split evenly over your workdays (35 h over Monday–Friday is 7:00 a day). |
| Work week | Monday to Friday | Your workdays: Monday–Friday, Monday–Saturday, or a custom set of days. |
| Workday starts at | 4 | Advanced. Hour at which a new workday begins; work after midnight and before it counts toward the previous day. |
| Duration format | 7:30 | How durations are displayed: `7:30`, `7h 30m` or `7.50 h`. |

## Notes

The `core` service starts automatically when the plugin is enabled. Shift stores its data as JSON files in
`~/.local/state/noctalia/plugins/data/hbollon/shift/` (`state.json`, `balance.json` and one `ledger/<year>.json` per
year). Disabling or removing the plugin never deletes them. Shift does not access the network or spawn processes yet.
