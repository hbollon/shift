<p align="center">
  <img src="assets/shift-logo.png" alt="Shift logo" width="128" />
</p>

# Shift user guide

Shift tracks your working time from the Noctalia shell. This guide covers everyday use; the [plugin page](../shift/README.md) lists every setting and IPC command.

- [Getting started](#getting-started)
- [Tracking your time](#tracking-your-time)
- [The dashboard](#the-dashboard)
- [Fixing a day](#fixing-a-day)
- [The overtime balance](#the-overtime-balance)
- [Automation](#automation)
- [Notifications](#notifications)
- [Keybinds and scripts](#keybinds-and-scripts)
- [Your data and backups](#your-data-and-backups)
- [Troubleshooting](#troubleshooting)

## Getting started

1. Install and enable Shift (see the [README](../README.md#-install)), then add the **Shift** widget to a bar.
2. Open the plugin settings and set your **weekly hours** and **work week**. Shift splits the hours evenly over your workdays: 35 h over Monday–Friday is a 7:00 daily target.
3. Open the dashboard (left-click the widget). A welcome card shows your contract; from there you can check in, adjust the settings, or set a starting balance if you already have overtime.

Tracking starts on the day you install Shift; days before it never count. You can move it in **Balance → Tracking**.

## Tracking your time

You are always in one of three states: **Off**, **Working**, or **Away** (working, but away from the computer).

| Where | Check in or out |
| --- | --- |
| Bar widget | Right-click. Left-click opens the dashboard; hover it for today's details. |
| Control-center tile | Click. Right-click opens the dashboard. |
| Dashboard | The **Check in** / **Check out** button. |
| Keybind or script | `noctalia msg plugin hbollon/shift:core all toggle` |

A session that runs past midnight counts toward the day it started: a workday ends at 04:00 by default (the *Workday starts at* setting). Made a mistake? Every action can be undone for 10 minutes, with the <kbd>↶</kbd> button in the dashboard header or <kbd>Ctrl</kbd>+<kbd>Z</kbd>.

## The dashboard

The header shows your status, and the hero shows today's worked time against your target, with the time left and when you'll be done. Three tabs sit below:

- **Today**: this week's total, your balance, today's delta, a timeline of the day and its sessions.
- **History**: a week of bars against the target, or a month calendar. Arrows mark days above or below target. Click a day to open it.
- **Balance**: your overtime balance and how it adds up, adjustments, and the tracking settings.

Cards at the top of the dashboard ask for your attention: an absence to review, a check-in suggestion, a day closed automatically, or days without any session. The footer summarises automation; its ⓘ button shows the signal sources and this week's work hours.

## Fixing a day

Click a day in **History** (or the pencil next to a session in **Today**) to open the day editor:

- **Edit sessions**: type times like `9:30`, `930`, `9h30` or `9.5`. You can change the start of the running session too ("I started at 8:30 but checked in at 9:00").
- **Add or delete sessions**, then **Save**.
- **Day off**: the day has no target, and any time worked on it is overtime. You can mark days off ahead of time.

A workday without any session stays out of the balance until you review it: mark it as a **day off**, **add a session**, or confirm it was **not worked** (its target then counts against you).

## The overtime balance

Your balance is the sum of:

- your **initial balance** (set it in **Balance → Tracking** if you start with overtime or a deficit);
- each day from the tracking start to yesterday: worked time minus target;
- your **adjustments**.

Today's delta is shown apart and joins the balance when the day ends. Days without a target (weekends, days off, public holidays) add all their worked time as overtime.

**Adjustments** record what your days don't show: time off taken from your overtime (`-7:00`), a correction from HR, hours paid out. Add them in **Balance → Add**, with an optional note.

**Public holidays** come from [date.nager.at](https://date.nager.at) for the country of your locale (or the *Holiday country* setting, plus a *Holiday region* for regional ones). They have no target. Turn *Public holidays* off if you don't want them.

**Changing your contract** applies from today: past days keep the targets they had.

## Automation

The **Automation** setting picks a preset:

| Preset | Check in / out | Absences |
| --- | --- | --- |
| Manual | You do everything. | Not tracked. |
| Assisted *(default)* | Suggested within your work hours. | Asks you. |
| Automatic | Done for you within your work hours. | Asks you. |
| Custom | Off, suggest or automatic, separately. | Count as work, ask, remove, or check out, per signal. |

**Work hours** (08:00–19:00 on your workdays by default) are where automation acts. A session you start outside them is never closed automatically, and a manual check-out pauses automatic check-ins until the current work hours end. *Additional rules* add or remove time, one per line:

```text
- * 12:00-13:30                lunch break, every day
- fri 16:00-24:00              short Fridays
+ sat 09:00-12:00              Saturday mornings
- 2026-12-24..2027-01-02       winter break
```

**Absences**: when you come back after at least 15 minutes inactive, with the screen locked, or with the computer asleep, Shift asks whether that time was work (a meeting, a call) or should be removed. Removing it splits your session around it. Shorter breaks always count as work. Absences you don't review count as work at the end of the day (see *Unreviewed absences*).

**End of day**: a session still open when the workday ends is closed at your last activity, and the day is flagged so you can check its end time.

Idle detection uses `swayidle`. Without it, Shift still follows the screen lock and sleep. To use your own idle daemon, set *Idle detection* to *External* and send `signal idle` / `signal active` (see the [plugin page](../shift/README.md#automation) for a hypridle example).

## Notifications

Shift sends three kinds of notifications, each with its own setting:

- **Daily target reached**: once a day, with your worked time and balance.
- **Absence to review**: when you come back from an absence that asks whether it was work.
- **Suggestions** (*Assisted* or *Custom*): when Shift suggests checking in or out, once per work-hours period.

## Keybinds and scripts

Every action is available over IPC, for compositor keybinds or scripts:

```sh
noctalia msg plugin hbollon/shift:core all toggle          # check in or out
noctalia msg plugin hbollon/shift:core all undo
noctalia msg plugin hbollon/shift:core all resolve keep    # or remove: the oldest absence to review
noctalia msg plugin hbollon/shift:core all adjust -2:00 Dentist
noctalia msg plugin hbollon/shift:core all dayoff 2026-12-24
noctalia msg panel-toggle hbollon/shift:dashboard
```

For example, in Hyprland: `bind = SUPER, F9, exec, noctalia msg plugin hbollon/shift:core all toggle`.

## Your data and backups

Shift keeps everything in `~/.local/state/noctalia/plugins/data/hbollon/shift/`: `state.json`, `balance.json` and one `ledger/<year>.json` per year. Disabling or removing the plugin never deletes them.

- **Backups**: every workday, Shift copies its data into `backups/daily/<date>/` (30 days kept), and the first one of each month into `backups/monthly/<month>/` (12 months kept).
- **Automatic restore**: if a file is damaged, Shift sets it aside with a `.corrupt` suffix, restores the newest backup that reads, and tells you its date.
- **Manual restore**: disable the plugin, copy the files of a backup directory over the ones in the data directory, then enable it again.

## Troubleshooting

- **The widget shows "Shift is starting…"**: the service is loading; with a long history, the balance takes a few seconds to compute the first time.
- **Absences are never detected**: install `swayidle`, or check the signal sources in the dashboard footer (ⓘ).
- **No public holidays**: check the *Holiday country* setting and your connection; the footer shows their status.
- **Something else**: [open an issue](https://github.com/hbollon/shift/issues/new) with Noctalia's log (`~/.cache/noctalia/noctalia.log`).
