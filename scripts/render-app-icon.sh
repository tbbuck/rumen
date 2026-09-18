#!/bin/bash
# Render the flat SVG masters into the legacy macOS .icns (for DMG art, docs, and any
# non-Xcode packaging). The app's real icon is the Icon Composer bundle
# Resources/AppIcon/AppIcon.icon, which actool compiles directly. Both the bundle and
# the masters come from design/icon/concepts.mjs via design/icon/export-app-icon.mjs.
#
# Requires rsvg-convert (brew install librsvg). Run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/Resources/AppIcon/Rumen-icon.svg"
SMALL="$ROOT/Resources/AppIcon/Rumen-icon-small.svg"
ICNS="$ROOT/Resources/AppIcon/Rumen.icns"
WORK="$(mktemp -d)"
ICONSET="$WORK/Rumen.iconset"
mkdir -p "$ICONSET"

# point size : scale. Renders at or below 32px use the hand-tuned small art.
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  pt="${spec%%:*}"
  scale="${spec##*:}"
  px=$((pt * scale))
  if [ "$scale" = "1" ]; then suffix=""; else suffix="@2x"; fi
  if [ "$px" -le 32 ]; then src="$SMALL"; else src="$MASTER"; fi
  rsvg-convert -w "$px" -h "$px" -o "$ICONSET/icon_${pt}x${pt}${suffix}.png" "$src"
done

iconutil -c icns -o "$ICNS" "$ICONSET"
rm -rf "$WORK"
echo "wrote $ICNS"
