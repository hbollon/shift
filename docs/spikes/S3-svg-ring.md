# S3 — Progress ring as generated SVG

| | |
|---|---|
| **Spec** | 0001 §5.2 C8, §7.2, §16 S3 |
| **Date** | 2026-10-09 |
| **Environment** | Noctalia 5.2.1 · 5120×2160 @ scale 1 · default dark palette |
| **Verdict** | ✅ **GO** — with a track color change |

## Question

Does a runtime-generated SVG rendered through `ui.image` look crisp in the bar and the panel, follow the palette, and
stay cheap when its path changes every second?

## Method

`spikes/shift-spike/lib/ring.luau` writes `cache/ring-<size>-<percent>-<paletteHash>.svg` (colors from
`noctalia.getColor`), shown in the bar (16 px) and the panel (160 px). Progress was set to 42 %, 72 % and 135 %
(overtime second lap), and animated at 1 Hz in both surfaces while sampling Noctalia's CPU time from `/proc`.
Rendering code was read in `src/ui/ui_tree_reconciler.cpp` and `src/render/core/image_file_loader.cpp`.

## Results

**Rendering.** Crisp at both sizes. The host rasterises SVGs with librsvg at **3× the logical size**
(`targetSize = max(w, h) * 3`), so HiDPI is covered. The overtime lap in `tertiary` over a full `primary` lap reads
clearly in both the 16 px and 160 px rings.

**Paths.** `data:` URIs are supported by the image loader, but **not reachable from plugins**: the bar/panel path
resolver prefixes anything not starting with `/` or `~` with the plugin directory. Cached files are required. A
changed path triggers a reload; the same path never reloads (content changes at an unchanged path are ignored),
which is why the palette hash belongs in the filename.

**Cost.**

| Scenario (20 s / 15 s samples) | Noctalia CPU |
|--------------------------------|--------------|
| Baseline (spike loaded, idle) | 0.13 % |
| Bar ring path changing every second | 0.20 % |
| Panel open, re-rendered every second (static ring) | ≈ 0.33–0.60 % |
| Panel + bar rings both changing every second | 0.65 % |

SVG generation + write: < 1 ms per miss. Cache growth: one file per (size, percent, palette); 53 files after the
animations.

**Visual issue.** The track drawn in `surface_variant` is almost invisible on the bar background and faint in the
panel (it is the same family of surface colors).

## Decisions for implementation

1. Keep the SVG ring (spec §7.2). Draw the **track with `on_surface` at `stroke-opacity` 0.15–0.20** instead of
   `surface_variant`, so it stays visible on any bar/panel surface. Arc `primary`, overtime lap `tertiary`.
2. Quantise progress to whole percents (≤ 201 files per size and palette); prune files whose palette hash is not
   current at service start.
3. Update rings at most once per minute (progress changes slowly); only the panel's seconds label ticks every second.
   Re-render the panel's full tree only when something other than the seconds label changed, if profiling in M3
   shows it matters.
4. Keep `ui.progress` as the fallback when the cache dir is not writable.

## Spec impact

- §7.2 Progress ring: track = `on_surface` at low opacity (not `surface_variant`).
