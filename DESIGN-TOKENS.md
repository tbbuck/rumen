# ArcGIS Explorer — Sheet design tokens

> Status: **Accepted** · 2026-09-16 · The exact palette, type, spacing and effect
> values behind the **Sheet** design language, as prototyped on the design canvas
> (`design/*.dc.html`). Companion to [UI-SPEC.md](./UI-SPEC.md). Source of truth for
> the SwiftUI Asset Catalog and `Theme`.

The app has its own token set. It does **not** reuse DuckLake Explorer's Stratum
tokens (SPEC §9, decision 15); what it shares with DuckLake is the shell mechanics,
not the look.

Two appearances: **Day** (sheet paper) is the base; **Night** (blue slate) applies
under the system dark appearance. In SwiftUI, define each token as a semantic colour
set with `Any` + `Dark` variants; a manual override in Preferences just sets
`.preferredColorScheme`.

## Colour

| Token | Day | Night | Role |
|---|---|---|---|
| `bg` | `#F2F4F0` | `#1A2128` | Window ground, layer page, inputs, the map sheet |
| `panel` | `#FAFBF8` | `#212930` | Title bar, tree, transfers strip and drawer, popovers |
| `line` | `#D6DBD2` | `#33404A` | Hairlines: row rules, tab rule, panel edges |
| `line2` | `#BEC5BA` | `#445362` | Control borders, window border, table top rule, sheet and locator frames |
| `grat` | `#C5D3E2` | `#34506A` | Graticule lines on the map sheet |
| `water` | `#DCE7F0` | `#22303D` | Water fill on the map sheet |
| `ink` | `#222A26` | `#E7EAE6` | Primary text |
| `muted` | `#5E6863` | `#A2ACA6` | Secondary text, fact labels, tab labels |
| `muted2` | `#8A948E` | `#7B867F` | Captions, ids, kind labels, tick labels, dimmed rows |
| `accent` | `#B8236B` | `#EA6AA6` | Landranger magenta: selection rail, links, primary button, current path segment, extent, sample points, progress |
| `accent-soft` | `rgba(184,35,107,.10)` | `rgba(234,106,166,.14)` | Selection fill, current path segment, locator fill, chips |
| `on-accent` | `#FFFFFF` | `#2A0F1D` | Text on an accent fill |
| `yes` | `#2E7D4F` | `#62B98A` | Extractable, done |
| `yes-soft` | `rgba(46,125,79,.12)` | `rgba(98,185,138,.16)` | Done chip |
| `no` | `#B3382D` | `#E07A70` | Not extractable, failed |
| `warn` | `#B8781F` | `#E2A64B` | Paused, retrying, stale |
| `warn-soft` | `rgba(184,120,31,.14)` | `rgba(226,166,75,.16)` | Paused chip |

**Rules**
- One accent. Magenta means "here" or "yours": the selected node, the current path
  segment, the layer's extent, the sample on the map, the running transfer. It never
  encodes a verdict.
- Verdicts use `yes` / `no` / `muted2` (unknown) and are always carried by a word,
  never by colour alone.
- Traffic lights are the system's. The mockups paint them `#E8615A` `#E3B04A`
  `#5FBE67` only because they are not real windows.
- Keep white and black tinted: nothing lighter than `panel`, nothing darker than
  Night `bg`.

## Typography

Two families, both SIL Open Font License, bundled in the app:

- **Cabin** — display, headings, UI, body. Weights 400 / 500 / 600 / 700. Gill and
  Johnston lineage, the same family tree as OS map covers.
- **Fira Code** — data: ids, field names, types, extents, paths, stats, tick labels.
  Weights 400 / 500. Ligatures **off** (data must read character for character);
  `tabular-nums` always.

System SF is used only where AppKit draws it: menus, alerts, native sheet buttons.

Expose as `Font.sheetDisplay(_:)`, `Font.sheetUI(_:)`, `Font.sheetMono(_:)`.

| Role | Face | Size / weight | Notes |
|---|---|---|---|
| Layer or page title | Cabin | 24 / 700 | `letter-spacing: -0.01em` |
| Server name (tree head) | Cabin | 14 / 700 | caption below in 11 / 400 `muted2` |
| Section heading (`Fields`, `Transfers`) | Cabin | 13.5 / 700 | sentence case, no rule |
| Transfer run name | Cabin | 13.5 / 700 | |
| Extraction statement | Cabin | 15 / 400 | line-height 1.5; the verdict word 700 in `yes` / `no` / `muted2` |
| Tabs | Cabin | 13 / 500 | `muted`; active `ink` with a 2px `accent` underline |
| Path bar segment | Cabin | 13 / 400 | `muted`; current segment 600 `ink` on `accent-soft` |
| Tree rows, fact list, body | Cabin | 12.5–13 / 400 | |
| Primary button | Cabin | 13 / 600 | small variant 12 / 600 |
| Links | Cabin | 12.5–13 / 400 | `accent`, underline on hover only |
| Table header | Cabin | 11 / 600 | `muted` |
| Captions, sub-lines | Cabin | 11–12.5 / 400 | `muted` or `muted2` |
| Chips (`PBF`, `Done`, `Paused`) | Cabin | 10.5 / 600 | |
| Service kind (`MapServer`) | Cabin | 9.5 / 400 | `muted2`, after the name |
| Data values | Fira Code | 12–12.5 / 400 | ids, fields, types, extents, paths |
| Strip and run stats | Fira Code | 11 / 400 | `muted` |
| Layer id in tree | Fira Code | 10.5 / 400 | `muted2`, right-aligned in a 14px column |
| Sheet tick labels | Fira Code | 8.5 / 400 | `muted2`; map marginalia only, never UI |

- Legibility floor for UI text is 9.5px; 8.5px is allowed only on the map margins.
- Line length in the extraction statement and captions ≤ 80 characters
  (`max-width: 720px`).

## Layout & sizing

**Window & chrome**
- Minimum window 1140 × 720. System window chrome; the mockups' 12px radius and
  1px `line2` border stand in for it.
- Title bar 48px, and it behaves like one: double-clicking it does what the system's
  "Double-click a window's title bar to" setting says (Zoom by default). The controls in
  it keep their own double-clicks; the path bar's empty area, whose single click enters
  edit mode, gives way when a second click follows within the double-click interval.
  Traffic lights, then the **path bar** (fills the width, 30px tall,
  radius 7, 1px `line2`, `bg` fill, 10px side padding, segments separated by 12px
  chevrons in `muted2`, a right-aligned mono tail such as `arcgis/rest/services`),
  then the column search field (190 × 30, radius 7).

**Main window** — two columns over a strip:
- **Tree 288px** by default, `panel`, 1px `line` right edge that drags between 220 and
  560px (a 9px grab zone with the column-resize pointer; the line turns `line2` while hovered
  or dragging; double-click resets to 288; the width is remembered), 14px top padding. Server header
  (name + caption) with 16px side padding. Rows 27px; indents 14 / 32 / 52px for
  folder / service / layer; chevron 10px; layer id column 14px; 7px gaps; 14px
  right padding. **Extent locator** 22 × 15 right-aligned in every row.
- **Layer page 1fr**, padding 22px top / 36px sides, vertical gap 18px.
  Tabs row: 24px gap, 8px bottom padding, 1px `line` rule. Extraction block
  max-width 720px. Actions row gap 18px. Fact list: 4-column grid
  `136px 1fr 126px 1fr`, gaps 6 × 20px, max-width 880px, values truncate with an
  ellipsis rather than wrap. Fields table: columns `160 150 130 100 1fr`, 14px gaps,
  rows 27px, header 26px, 1px `line2` top rule, 1px `line` row rules.
- **Transfers strip 40px** along the bottom: label, status dot 8px, run name,
  progress bar 220 × 4 radius 2, mono stats, right-aligned "Show all n". The whole strip
  opens the drawer and the drawer's whole 40px header closes it (both hover `line` at 0.5
  with the pointing hand); the links and the chevron inside keep their own clicks.
- **Transfers drawer** grows from the strip to 340px: 40px header (label, summary,
  collapse chevron) + run rows. Run row grid `1fr 220px 214px`, 24px gaps, 12px
  vertical padding, 1px `line` rules.

**Components**
- **Extent locator**: 22 × 15 frame, 1px `line2`; the node's bbox as a rect filled
  `accent-soft`, stroked `accent`, proportional to the server's union extent.
  Not extractable: no fill, `muted2` dashed `1.5 1.5`. Table (no geometry): frame
  only, dashed `2 2`.
- **Chunk grid**: 7px cells, 2px gaps, radius 1.5. Pending `line`, done `accent`, in
  flight `accent-soft` with a 1px inset `accent` ring, retrying `warn`. 23 columns for up
  to eight rows; a bigger plan widens the grid first, up to 48 columns (430px, taken from
  the row's text column), and only then adds rows. Cells never shrink and nothing scrolls:
  the run row grows to fit, with its text top-aligned.
- **Run progress bar** (finished, paused, or non-chunked runs): 6px, radius 3;
  `yes` when done, `warn` when paused, `accent` while running.
- **Map sheet**: 1px `line2` frame, `bg` fill; margins left 34 / top 22 /
  right 14 / bottom 26px carrying tick labels (eastings top and bottom, northings
  rotated on the left). Graticule 60px cells (5 km at the sketch's zoom); ticks every
  second line. Layer extent 1.5px dashed `accent`; sample points 4px `accent`
  circles; zoom control 26px cells, radius 6, `panel`, 1px `line2`, top-right at
  10 / 10px inside the frame.
- **Buttons**: primary 30px tall, 12px side padding, radius 6, `accent` fill,
  `on-accent` text; small primary 26px / 10px / 12px text. Secondary actions are
  links, not outlined buttons.
- **Inputs**: 30px tall, radius 7, 1px `line2`, `bg` fill, 9px side padding,
  placeholder `muted2`.
- **Chips**: 2px 7px padding, radius 5, `accent-soft` / `accent` by default;
  `yes-soft` / `yes` for Done; `warn-soft` / `warn` for Paused.
- **Status dot**: 8px circle; `accent` running, `yes` done, `warn` paused, `muted2`
  queued.
- Sheets and popovers: radius 10, 1px `line2`, `panel` fill.

**Borders, focus, shadows**
- Hairlines 1px `line`; control borders 1px `line2`.
- Selection: `accent-soft` fill + `inset 2px 0 0 accent` left rail (tree rows);
  current path segment: `accent-soft` fill, radius 5.
- Focus ring: `2px solid accent`, `outline-offset: 2px`.
- Shadows: only on sheets, popovers and the drawer's top edge —
  `0 30px 70px -25px rgba(0,0,0,.45)` for sheets, `0 -6px 18px -12px rgba(0,0,0,.25)`
  for the drawer. Nothing else casts a shadow.

**Spacing & motion**
- Side gutter 36px in the layer page, 16px in the tree; panel padding 14–18px.
- Transitions `.12s ease` on hover / active only; drawer open and close
  `.18s ease-out`. **Respect reduced motion** (disable all). No ambient motion: live
  chunk cells do not pulse, progress bars step rather than animate.
