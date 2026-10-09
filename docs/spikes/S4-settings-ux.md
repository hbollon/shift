# S4 — Schedule rules in the settings GUI

| | |
|---|---|
| **Spec** | 0001 §6.3.3, §8, §16 S4 |
| **Date** | 2026-10-09 |
| **Environment** | Noctalia 5.2.1 settings window (Settings → Plugins → gear) |
| **Verdict** | ⚠️ **NO-GO for "DSL list only"** → ✅ **GO for the hybrid model** (decided with the user) |

## Question

Is a `string_list` setting comfortable enough to author and maintain schedule rules, and do the other planned setting
shapes (`select` presets, `visible_when`, `advanced`) behave as the spec assumes?

## Method

`spikes/shift-spike/plugin.toml` declares the spec's settings shapes; the service logs `getConfig` read-backs on
`onConfigChanged`; the settings page was inspected visually and the list control read in
`src/ui/controls/list_editor.h` / `src/shell/settings/settings_control_factory.cpp`.

## Results

| Aspect | Result |
|--------|--------|
| `getConfig("schedule_rules")` | ✅ Luau array of strings, order preserved |
| `onConfigChanged` | ✅ fires in the service, values updated in place |
| `select` + `visible_when` | ✅ dependent settings hidden/shown live (custom-only and `work_week = custom` toggles) |
| `advanced = true` | ✅ shown with an "Advanced" badge only when the window's advanced toggle is on |
| `int` with `min`/`max` | ✅ slider + numeric field |
| Host-injected panel settings | ✅ appear as "`<entry id>` · Placement / Along the bar" — the entry id is user-visible |
| `string_list` editor | ⚠️ narrow "Add an entry…" field (~190 px), each item with remove ✕ and move ↑/↓, **no in-place editing** |

Correcting a rule therefore means removing it and retyping it in a short field; long rules are cramped. The validation
feedback can only live in our panel, away from where the user types. Acceptable for occasional power-user exceptions,
not for the main schedule that every user configures.

## Decision (with the user): hybrid settings

The common case uses typed, editable settings; the DSL list remains for exceptions:

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `window_start` | string `HH:MM` | `"08:00"` | Start of the automation window on contract workdays |
| `window_end` | string `HH:MM` | `"19:00"` | End of the window (`24:00` allowed) |
| `window_exclude_holidays` | bool | `true` | Public holidays are outside the window |
| `extra_rules` | string_list | `[]` | Additional `+`/`-` DSL rules (§6.3.3 grammar), e.g. `- * 12:00-13:30` |

Semantics: the base window is the implicit rule `+ <contract workdays> <window_start>-<window_end>`, plus
`- holidays` when `window_exclude_holidays` is on. Days off are always excluded. `extra_rules` are evaluated on top
with the same precedence (exclusions win). The days of the window follow the contract workdays (`work_week`), so the
user configures their week once.

Invalid `HH:MM` values or rules are reported in the panel's automation section with **[Edit in settings]**; the 7×24
preview shows the effective result.

## Other findings for implementation

1. Name the panel entry with a user-meaningful id (`dashboard` rather than `panel`) since Noctalia shows it as a
   settings prefix.
2. `HH:MM` strings are validated by the service (no time type exists in the settings schema).

## Spec impact

- §6.3.3: base window from typed settings + `extra_rules` DSL (replaces `schedule_rules`).
- §8.3: replace `schedule_rules` with `window_start`, `window_end`, `window_exclude_holidays`, `extra_rules`.
- §9.1 / §14: panel entry id `dashboard`.
- D19 unchanged in substance (08:00–19:00, Mon–Fri via contract, holidays excluded); new decision for the hybrid model.
