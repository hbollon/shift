# M0 — Technical spikes

Throwaway experiments validating the risky platform assumptions of
[spec 0001 §16](../specs/0001-shift-v1.md#16-risks-and-technical-spikes) before implementation. Run on 2026-10-09
against Noctalia 5.2.1 (`plugin_api` 32) on Hyprland.

| Spike | Topic | Verdict | Spec changes |
|-------|-------|---------|--------------|
| [S1](S1-swayidle-runstream.md) | swayidle through `runStream` | ✅ GO | Activity while locked does not count (§6.3.2) |
| [S2](S2-logind-monitoring.md) | logind lock/sleep monitoring | ✅ GO | Fallback is `loginctl` polling, not `busctl` (§16) |
| [S3](S3-svg-ring.md) | Generated SVG progress ring | ✅ GO | Ring track uses `on_surface` at low opacity (§7.2) |
| [S4](S4-settings-ux.md) | Schedule rules in the settings GUI | ⚠️ DSL-only rejected → ✅ hybrid | Typed window settings + `extra_rules` (§6.3.3, §8.3, D29); panel entry id `dashboard` |
| [S5](S5-state-channel.md) | State channel throughput and semantics | ✅ GO with change | Per-sender commands with ack/retry (§9.3, D30) |

## Reproducing

The spike plugin lives in [`spikes/shift-spike/`](../../spikes/shift-spike/) (`hbollon/shift-spike`). It logs to
`~/.local/state/noctalia/plugins/data/hbollon/shift-spike/spike-*.log` because Noctalia's own log may go to
`/dev/null`.

```sh
noctalia msg plugins source add shift-dev path ~/shift/spikes
noctalia msg plugins enable hbollon/shift-spike
# optional: put the widget on a bar
#   [widget.shift_spike]
#   type = "hbollon/shift-spike:bar"

noctalia msg plugin hbollon/shift-spike:core all idle          # S1 (needs swayidle)
noctalia msg plugin hbollon/shift-spike:core all session       # S2 session path
noctalia msg plugin hbollon/shift-spike:core all monitor gdbus # S2 monitor
noctalia msg plugin hbollon/shift-spike:core all bench 1000    # S5
noctalia msg plugin hbollon/shift-spike:core all same          # S5 watch semantics
noctalia msg plugin hbollon/shift-spike:bar all progress 1.35  # S3 overtime lap
noctalia msg panel-toggle hbollon/shift-spike:panel            # S3 panel ring
noctalia msg plugin hbollon/shift-spike:core all settings      # S4 settings page

noctalia msg plugins disable hbollon/shift-spike
noctalia msg plugins source remove shift-dev
```
