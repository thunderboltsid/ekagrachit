#!/usr/bin/env bash
# Builds Ekagrachit.app (menu bar app + bundled native messaging host).
#   scripts/build-app.sh                 # release build (macOS 26+, Apple Silicon)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
# Output: apps/macos/build/Ekagrachit.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${ROOT:?}/apps/macos"
CONFIG="${CONFIG:-release}"
[[ "$(uname)" == "Darwin" ]] || { echo "build-app.sh must run on macOS" >&2; exit 1; }

cd "$PKG"
ARCH_FLAGS=(--arch arm64)
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Ekagrachit
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ekagrachit-host
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="${PKG:?}/build/Ekagrachit.app"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ekagrachit" "$APP/Contents/MacOS/Ekagrachit"
cp "$BIN/ekagrachit-host" "$APP/Contents/MacOS/ekagrachit-host"
cp "$PKG/Resources/Info.plist" "$APP/Contents/Info.plist"

# The Chrome extension ships inside the app; at launch the app copies it to
# ~/Library/Application Support/Ekagrachit/Chrome Extension for Chrome to load.
EXT="${ROOT:?}/extensions/chrome/dist"
[[ -f "$EXT/manifest.json" ]] || { echo "Build the extension first: (cd extensions/chrome && npm ci && npm run build)" >&2; exit 1; }
cp -R "$EXT" "$APP/Contents/Resources/ChromeExtension"
find "${APP:?}/Contents/Resources/ChromeExtension" -name '*.map' -delete
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature by default. macOS ties the Accessibility grant to the
# signature, so after rebuilding an ad-hoc build you may need to re-grant it.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier io.github.thunderboltsid.ekagrachit.host "$APP/Contents/MacOS/ekagrachit-host"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP"
