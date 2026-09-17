# App icon

The design is **not decided**. This folder holds the current candidates and the tooling
that makes and reviews them; every candidate exists as a flat master *and* as an Icon
Composer bundle that actool compiles exactly as Xcode would. Earlier rounds' conclusions
were deliberately not carried over; the standing brief is the mechanics below and one
caution from Tom: no clusters of small dots.

Current direction (2026-09-17): **Peel**, a white map sheet with a lifted corner on OS
Explorer orange, being iterated on how strongly the curl reads. Locator (the extent
locator glyph on Landranger magenta) is kept in `concepts.mjs`, unbuilt.

## Files

| File | Role |
|---|---|
| `concepts.mjs` | **The concepts and every design decision**: per concept its palette, its layers (bottom first) and a hand-tuned `small` variant for 32px and below. |
| `<key>.svg`, `<key>-small.svg` | Flat masters (1024px, squircle tile baked in), generated. The `-small` master is the 32/16px art. |
| `bundles/<Name>.icon/` | Icon Composer bundles derived from the same layers: `icon.json` + one full-canvas SVG per layer under `Assets/`. Generated; `flatOnly` layers (hard shadows) are left out because the group shadow does that job. Delete the folder before a build that renames layers. |
| `icon-lib.mjs` | The mechanics: Apple's squircle tile, the 1024px flat-master wrapper, lon/lat → tile-px projection, clip-free drawing helpers (dashes, rings, grids, ticks, ribbons and Chaikin smoothing as filled paths; Sutherland–Hodgman clipping to convex shapes), the layered-concept → flat master + bundle derivation, and the preview-page builder. |
| `build-icons.mjs` | CLI: `node design/icon/build-icons.mjs design/icon/concepts.mjs <preview-dir> [renders-dir]`. Writes the SVGs and bundles here and `icon-preview.html` (standalone) + `arcgis-explorer-icon.html` (Artifact fragment) to the preview dir; with a renders dir it embeds the actool output too. |
| `geography.sql`, `geography.json`, `geography-bold.json` | DuckDB spatial + httpfs query against Overture Maps division areas: Great Britain and Ireland as land polygons, generalised to logo grade at two strengths. Committed output. Derived from OpenStreetMap (ODbL): a "Contains OpenStreetMap data" credit belongs in About if it ships. |

Review tooling outside the repo (ignored, under `claude-scripts/`):

- `icon_contact_sheet.sh <out-dir> [svg-dir]` renders every flat master (the `-small`
  master at 32 and 16) with rsvg-convert, bakes the Dock shadow, and writes a light
  contact sheet, a greyscale copy, and light and dark 64px Dock strips.
- `icon_compile_bundles.sh <bundles-dir> <out-dir>` compiles every bundle with
  `xcrun actool`, unpacks the icns (actool writes 16, 32, 128 and 256), and writes
  `<key>-<px>.png` for `build-icons.mjs` plus Dock strips of the real, glass-applied renders.

## Layer rules (what Icon Composer will and will not render)

- Layers are full-canvas 1024×1024; the system applies the squircle, so tile coordinates
  are scaled by 1024/824 inside each layer (`layerSvg` does this).
- **Arrays in `icon.json` are top-to-bottom**; `iconJson` reverses the bottom-first list.
  Get it wrong and lower layers vanish silently.
- Shapes, paths, fills, `fill-opacity` and gradients only. No strokes, dashes, masks,
  clipPath, filters or text: dashes are rects, frames and rings are two-winding paths,
  grids are rects, lines are ribbons, and anything cut to a circle or a panel is clipped
  geometrically. A layer's opacity lives in `icon.json`, not in its SVG.
- `glass: true` per layer; `shadow`, `specular`, `translucency`, `lighting` per group.

## Making the real icon (from DuckLake Explorer)

- Add the chosen `AppIcon.icon/` to `project.yml` as `type: file` and reference it with
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; actool renders every size.
- macOS 26 icons can carry a dark appearance in the same bundle.
- The legacy `.icns` (DMG art, docs) comes from the flat master plus the `-small` master
  for 16 and 32px via rsvg-convert + iconutil (`scripts/render-app-icon.sh` in DuckLake
  Explorer is the template).
