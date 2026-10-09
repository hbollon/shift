# Shift

Track your working hours from the Noctalia shell: one-click check in / check out, a live daily counter against your
contract, and an overtime balance you can adjust. Shift is under active development; this release is a scaffold.

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

## Notes

The `core` service starts automatically when the plugin is enabled. Shift does not access the network, spawn processes
or write files yet.
