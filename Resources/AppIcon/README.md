# App icon

**Peel**: a white map sheet on OS Explorer orange with its bottom-right corner lifted (the
layer coming away from the server), a faint survey-blue grid and a Landranger-magenta
extent, the app's own map language and UI accent. Chosen 2026-09-17.

Everything in this folder is **generated** from `design/icon/concepts.mjs`. Edit the
concept, not these files.

| File | Role |
|---|---|
| `AppIcon.icon/` | **The app icon.** Icon Composer bundle (Liquid Glass): `icon.json` + one 1024px full-canvas SVG per layer under `Assets/`. Referenced from `project.yml` (`type: file`, resources phase) and `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; actool renders every size from it. |
| `ArcGISExplorer-icon.svg` | Flat master of the same design, Apple's squircle tile baked in. |
| `ArcGISExplorer-icon-small.svg` | Hand-tuned art for 16px and 32px: no grid, a heavier extent, a darker flap. |
| `ArcGISExplorer.icns` | Legacy icns built from the two flat masters by `scripts/render-app-icon.sh`. For DMG art, docs, and non-Xcode packaging only. |

## Regenerating

```sh
node design/icon/export-app-icon.mjs design/icon/concepts.mjs peel Resources/AppIcon
scripts/render-app-icon.sh        # flat masters -> ArcGISExplorer.icns
scripts/render-icon-bundle.sh     # compile AppIcon.icon with actool and unpack it to look
xcodegen generate                 # only needed if project.yml changed
```

Bundle rules (layers are shapes and fills only, arrays top-to-bottom, glass per layer) are
in `design/icon/README.md`.
