# App icon

The design is **not decided**. This folder holds four candidates (2026-09-17) and the
tooling that makes and reviews them, so every candidate exists as a flat master *and*
as an Icon Composer bundle that actool compiles exactly as Xcode would.

## Files

| File | Role |
|---|---|
| `concepts.mjs` | **The four concepts and every design decision**: palette, the query extent, and per concept its layers (bottom first) plus a hand-tuned `small` variant for 32px and below. A · Survey sheet, B · Folded map, C · Pulled layer, D · Lens. |
| `sheet.svg` `fold.svg` `stack.svg` `lens.svg` | Flat masters (1024px, squircle tile baked in), generated. `*-small.svg` beside each is the 32/16px art. |
| `bundles/<Name>.icon/` | Icon Composer bundles derived from the same layers: `icon.json` + one full-canvas SVG per layer under `Assets/`. Generated; `flatOnly` layers (hard shadows) are left out because the group shadow does that job. |
| `icon-lib.mjs` | The mechanics: Apple's squircle tile, the 1024px flat-master wrapper, lon/lat → tile-px projection, clip-free drawing helpers (dashes, rings, grids, ticks as filled paths; Sutherland–Hodgman clipping to convex shapes), the layered-concept → flat master + bundle derivation, and the preview-page builder. |
| `build-icons.mjs` | CLI: `node design/icon/build-icons.mjs design/icon/concepts.mjs <preview-dir> [renders-dir]`. Writes the SVGs and bundles here and `icon-preview.html` (standalone) + `arcgis-explorer-icon.html` (Artifact fragment) to the preview dir; with a renders dir it embeds the actool output too. |
| `geography.sql` | DuckDB spatial + httpfs query against Overture Maps division areas: Great Britain and Ireland as land polygons, unioned, then generalised to logo grade (closing → opening → Douglas-Peucker), two strengths. `duckdb -f design/icon/geography.sql`. Needs network; ~30 s. |
| `geography.json`, `geography-bold.json` | Its output, committed so builds need no network. The concepts use the bold file, first two parts only (the Outer Hebrides read as a stain). Derived from OpenStreetMap (ODbL): a "Contains OpenStreetMap data" credit belongs in About if this coastline ships. |

Review tooling outside the repo (ignored, under `claude-scripts/`):

- `icon_contact_sheet.sh <out-dir> [svg-dir]` renders every flat master (the `-small`
  master at 32 and 16) with rsvg-convert, bakes the Dock shadow, and writes a light
  contact sheet, a **greyscale** copy of it, and light and dark 64px Dock strips. The
  greyscale sheet is the test that matters: if elements merge there, they merge in the Dock.
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
  grids are rects, and anything cut to a circle or a panel is clipped geometrically.
- `glass: true` per layer; `shadow`, `specular`, `translucency`, `lighting` per group.
  Glass on the petrol land gives it an enamel look; glass on line-work looks wrong.

## Making the real icon (from DuckLake Explorer)

- Add the chosen `AppIcon.icon/` to `project.yml` as `type: file` and reference it with
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; actool renders every size.
- macOS 26 icons can carry a dark appearance in the same bundle.
- The legacy `.icns` (DMG art, docs) comes from the flat master plus the `-small` master
  for 16 and 32px via rsvg-convert + iconutil (`scripts/render-app-icon.sh` in DuckLake
  Explorer is the template).

## What the attempts so far established

- Scattered points read as a petri dish; invented polygons read as blobs; a solid
  silhouette of a real coastline still reads as a stain unless the shape is famous.
- The British Isles, generalised hard (closing 0.14°, opening 0.08°, simplify 0.05°, two
  islands only), are recognisable at 16px.
- Magenta reads as red, and red means danger, at Dock size. Petrol `#116C7E` is the
  surviving colour; ink slate the runner-up.
- Contrast must be built in **value**, not hue: pale ground, pale sheets, pale water and
  sand average to one beige at 64px. Check in greyscale. The 2026-09-17 set uses a
  fixed ladder: paper 97 · sea 91 · desk 70 · petrol 41 · ink 19 (L*).
- Coloured tiles were rejected as ugly; a light tile with sheets stepping down in value
  was the direction with life in it, and letting the outer sheets overflow the tile's
  corners gives the front sheet more room without more detail.
- Twelve ticks around a ring make a stopwatch, not a bearing ring.
- Present iterations of what was asked, and nothing else alongside.
