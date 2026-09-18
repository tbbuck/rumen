#!/usr/bin/env bash
#
# Build → bundle engine → Developer ID sign (hardened runtime) → self-test → notarize →
# staple → DMG. Produces a distributable, notarized "Rumen.dmg" whose app runs on a
# clean Mac with no Homebrew or DuckDB installed (M9, as in DuckLake Explorer).
#
# Requirements:
#   - A "Developer ID Application" identity in the login keychain.
#   - A notarytool keychain profile (default name: arcgis-notary), created once with:
#       xcrun notarytool store-credentials "arcgis-notary" \
#         --apple-id <you@example.com> --team-id <TEAMID>
#     (it prompts for an app-specific password).
#
# Env overrides:
#   CODESIGN_IDENTITY  signing identity            (default: "Developer ID Application")
#   NOTARY_PROFILE     notarytool keychain profile (default: arcgis-notary)
#   SKIP_NOTARIZE=1    sign + package only, no notarization (local pipeline testing)
#   BUILD_DIR          where DerivedData and the DMG land (default: <repo>/build)
#
# No MapTiler key is baked into a release: the app reads MAPTILER_API_KEY from its environment
# at run time (see Sources/App/MapConfig.swift).
#
set -euo pipefail

R="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME=Rumen
CONFIG=Release
APP_NAME="Rumen"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-arcgis-notary}"
ENTITLEMENTS="$R/Config/Rumen.entitlements"

BUILD_DIR="${BUILD_DIR:-$R/build}"
DDP="$BUILD_DIR/DerivedData"
APP="$DDP/Build/Products/$CONFIG/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"
ZIP="$BUILD_DIR/$APP_NAME.zip"

cd "$R"
mkdir -p "$BUILD_DIR"

echo "==> 1/6  Generate + build ($CONFIG)"
xcodegen generate
xcodebuild -project Rumen.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DDP" -quiet clean build

# The version shipped comes from project.yml, and the release is triggered by a tag: nothing
# connects the two, so tagging v1.3.0 without bumping MARKETING_VERSION would notarise and
# publish a DMG that calls itself 1.2.0. Checked here, before anything expensive or public.
TAG="${GITHUB_REF_NAME:-}"
case "$TAG" in
  v*)
    BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    if [ "v$BUILT" != "$TAG" ]; then
      echo "release: tag $TAG does not match the built version $BUILT — bump MARKETING_VERSION in project.yml" >&2
      exit 1
    fi
    echo "    version $BUILT matches tag $TAG"
    ;;
esac

echo "==> 2/6  Bundle libduckdb"
"$R/scripts/bundle-duckdb-engine.sh" "$APP"

echo "==> 3/6  Sign (Developer ID + hardened runtime)"
# Bundled dylib first, then the app last. The app carries the disable-library-validation
# entitlement so it can dlopen the spatial extension DuckDB installs at runtime. No extension
# is bundled, so the whole thing --deep --strict verifies cleanly.
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/libduckdb.dylib"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 4/6  Self-test the signed app (installs + loads spatial at runtime)"
out="$("$APP/Contents/MacOS/$APP_NAME" --selftest)"
echo "    $out"
case "$out" in
  "selftest OK"*) : ;;
  *) echo "release: signed app failed its engine self-test" >&2; exit 1 ;;
esac

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> 5/6  Notarize — SKIPPED (SKIP_NOTARIZE=1)"
else
  echo "==> 5/6  Notarize + staple"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  # Prove the ticket is actually attached. `spctl` below can be satisfied by an online check,
  # so it passes even when stapling silently did not — and then the first person to open the
  # app offline, or behind a firewall that blocks Apple, is the one who finds out.
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
fi

echo "==> 6/6  Package DMG"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo
echo "Done: $DMG"
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  spctl --assess --type execute --verbose=2 "$APP" || true
fi
