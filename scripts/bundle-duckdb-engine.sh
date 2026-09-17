#!/usr/bin/env bash
#
# Bundle libduckdb into a built "ArcGIS Explorer.app" and rewrite install names so the app needs
# no Homebrew at runtime. Idempotent: safe to run repeatedly on the same bundle.
#
# Only libduckdb is bundled. The spatial extension is NOT: a .duckdb_extension carries a
# metadata+signature footer after the Mach-O that Apple's notary rejects, and DuckDB confirms
# signing dynamically loaded extensions is not currently possible (duckdb/duckdb#16926). The app
# installs it at runtime into Application Support and loads it under the
# disable-library-validation entitlement (see Sources/App/EngineSupport.swift).
#
# It does NOT codesign; signing and notarization live in scripts/release.sh.
#
#   Usage: scripts/bundle-duckdb-engine.sh "/path/to/ArcGIS Explorer.app"
#
# Optional override (CI or non-standard installs):
#   DUCKDB_LIB=/abs/libduckdb.dylib   pin the source dylib explicitly
#
set -euo pipefail

APP="${1:?usage: bundle-duckdb-engine.sh <path-to-.app>}"
[ -d "$APP" ] || { echo "error: not an app bundle: $APP" >&2; exit 1; }

# --- Resolve the source dylib ------------------------------------------------------------
SRC_DYLIB="${DUCKDB_LIB:-}"
if [ -z "$SRC_DYLIB" ]; then
  for cand in \
    "$(brew --prefix duckdb 2>/dev/null || true)/lib/libduckdb.dylib" \
    /opt/homebrew/opt/duckdb/lib/libduckdb.dylib \
    /usr/local/opt/duckdb/lib/libduckdb.dylib; do
    [ -f "$cand" ] && { SRC_DYLIB="$cand"; break; }
  done
fi
[ -f "$SRC_DYLIB" ] || { echo "error: libduckdb.dylib not found (set DUCKDB_LIB)" >&2; exit 1; }

# --- Copy into Contents/Frameworks and fix its install name ------------------------------
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
DST_DYLIB="$FRAMEWORKS/libduckdb.dylib"
cp -f "$SRC_DYLIB" "$DST_DYLIB"
chmod u+w "$DST_DYLIB"
install_name_tool -id "@rpath/libduckdb.dylib" "$DST_DYLIB"

# --- Rewrite the main executable's libduckdb reference and rpath (idempotent) ------------
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BIN="$APP/Contents/MacOS/$EXE_NAME"
[ -f "$BIN" ] || { echo "error: executable not found: $BIN" >&2; exit 1; }

current_ref="$(otool -L "$BIN" | awk '/libduckdb\.dylib/ {print $1; exit}')"
if [ -n "$current_ref" ] && [ "$current_ref" != "@rpath/libduckdb.dylib" ]; then
  install_name_tool -change "$current_ref" "@rpath/libduckdb.dylib" "$BIN"
fi
if ! otool -l "$BIN" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
fi
# Drop any absolute Homebrew rpath so a dev machine's libduckdb cannot shadow the bundled copy.
while read -r stale; do
  [ -n "$stale" ] && install_name_tool -delete_rpath "$stale" "$BIN" || true
done < <(otool -l "$BIN" | awk '/ path / && /duckdb/ {print $2}')

echo "bundled libduckdb into: $APP"
