# App icon — mechanics

The design is not decided. This folder holds the **tooling** for making and reviewing
candidates, plus the geography data, so the next attempt starts from the mechanics
rather than from nothing. There is no artwork here on purpose.

## Files

| File | Role |
|---|---|
| `icon-lib.mjs` | The mechanics: Apple's squircle tile path, the 1024px flat-master wrapper, lon/lat → tile-px projection helpers, a graticule helper, and the preview-page builder (standalone page + Artifact fragment, each concept at 256/128/64/32/16 with light and dark Dock strips). |
| `build-icons.mjs` | CLI: `node design/icon/build-icons.mjs <concepts.mjs> <preview-dir>`. The concepts module default-exports `async (lib) => [{ key, file, name, svg, why, tradeoff }]` and holds every design decision. |
| `geography.sql` | DuckDB spatial + httpfs query against Overture Maps division areas: Great Britain and Ireland as land polygons, unioned, then generalised to logo grade (closing → opening → Douglas-Peucker), two strengths. `duckdb -f design/icon/geography.sql`. Needs network; ~30 s. |
| `geography.json`, `geography-bold.json` | Its output, committed so builds need no network. `lib.loadFeature(file)` turns either into one MultiPolygon. Derived from OpenStreetMap (ODbL): a "Contains OpenStreetMap data" credit belongs in About if this coastline ships. |

Review tooling outside the repo (ignored): `claude-scripts/icon_contact_sheet.sh <out-dir> [svg-dir]`
renders every SVG in a folder with rsvg-convert, bakes the Dock shadow with ImageMagick,
and writes a light contact sheet, a **greyscale** copy of it, and a dark 64px Dock strip.
The greyscale sheet is the test that matters: if elements merge there, they merge in the Dock.

## Making the real icon (from DuckLake Explorer)

- The app icon is an **Icon Composer bundle** `AppIcon.icon/` (`icon.json` + one 1024px
  full-canvas SVG per layer under `Assets/`), added to `project.yml` as `type: file` and
  referenced by `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; actool renders every size.
- Layers are full-canvas; the system applies the squircle. **Arrays are top-to-bottom**:
  the first group and the first layer in a group render on top. Get it wrong and lower
  layers vanish silently. `glass: true` per layer; `shadow`, `specular`, `translucency`,
  `lighting` per group; top-level `fill` is the tile background. Keep layer SVGs to
  shapes, paths, fills and gradients: no filters, masks or text.
- macOS 26 icons can carry a dark appearance in the same bundle.
- The legacy `.icns` (DMG art, docs) comes from a flat squircle master plus hand-tuned
  art for 16 and 32px via rsvg-convert + iconutil (`scripts/render-app-icon.sh` in
  DuckLake Explorer); `scripts/render-icon-bundle.sh` there compiles a `.icon` with
  actool for a quick look.

## What the earlier attempts established

- Scattered points read as a petri dish; invented polygons read as blobs; a solid
  silhouette of a real coastline still reads as a stain unless the shape is famous.
- The British Isles, generalised hard (closing 0.14°, opening 0.08°, simplify 0.05°, two
  islands only), are recognisable at 16px.
- Magenta reads as red, and red means danger, at Dock size. Petrol `#116C7E` was the
  surviving accent; ink slate `#34475A` the runner-up.
- Contrast must be built in **value**, not hue: pale ground, pale sheets, pale water and
  sand average to one beige at 64px. Check in greyscale.
- Coloured tiles were rejected as ugly; a light tile with sheets stepping down in value
  was the direction with life in it, and letting the outer sheets overflow the tile's
  corners gives the front sheet more room without more detail.
- Present iterations of what was asked, and nothing else alongside.
