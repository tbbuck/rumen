#!/bin/bash
# Compile an Icon Composer .icon bundle with actool (exactly as Xcode does) and unpack
# the resulting icns so the rendering can be eyeballed without a full app build. Useful
# for checking layer order, glass, and small sizes.
#
# usage: scripts/render-icon-bundle.sh [path/to/Name.icon] [out-dir]
# defaults: Resources/AppIcon/AppIcon.icon, a fresh temp dir (path is printed)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="${1:-$ROOT/Resources/AppIcon/AppIcon.icon}"
OUT="${2:-$(mktemp -d)}"
NAME="$(basename "$ICON" .icon)"
mkdir -p "$OUT/compiled"

xcrun actool "$ICON" --compile "$OUT/compiled" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon "$NAME" --output-partial-info-plist "$OUT/partial.plist" > "$OUT/actool.log" 2>&1 \
  || { cat "$OUT/actool.log"; exit 1; }
iconutil -c iconset -o "$OUT/unpacked.iconset" "$OUT/compiled/$NAME.icns"
echo "$OUT/unpacked.iconset"
ls "$OUT/unpacked.iconset"
