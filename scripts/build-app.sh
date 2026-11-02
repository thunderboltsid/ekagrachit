#!/usr/bin/env bash
# Builds Ekagrachit.app (menu bar app + bundled native messaging host).
#   scripts/build-app.sh                 # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
# Output: apps/macos/build/Ekagrachit.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${ROOT:?}/apps/macos"
CONFIG="${CONFIG:-release}"
[[ "$(uname)" == "Darwin" ]] || { echo "build-app.sh must run on macOS" >&2; exit 1; }

cd "$PKG"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Ekagrachit
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ekagrachit-host
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="${PKG:?}/build/Ekagrachit.app"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ekagrachit" "$APP/Contents/MacOS/Ekagrachit"
cp "$BIN/ekagrachit-host" "$APP/Contents/MacOS/ekagrachit-host"
cp "$PKG/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature by default. macOS ties the Accessibility grant to the
# signature, so after rebuilding an ad-hoc build you may need to re-grant it.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier io.github.thunderboltsid.ekagrachit.host "$APP/Contents/MacOS/ekagrachit-host"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP"
