#!/usr/bin/env bash
# Builds the release artifacts into dist/ (macOS only):
#   Ekagrachit-<v>.dmg                    app + Applications shortcut
#   ekagrachit-chrome-extension-<v>.zip   unpacked extension (sideload / "Load unpacked")
#   ekagrachit-chrome-web-store-<v>.zip   upload for the Chrome Web Store (no "key" field)
#   SHA256SUMS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname)" == "Darwin" ]] || { echo "package-release.sh must run on macOS" >&2; exit 1; }
V="$(node -p 'require("./extensions/chrome/manifest.json").version')"
OUT="${ROOT:?}/dist"
rm -rf "${OUT:?}" && mkdir -p "$OUT"

(cd extensions/chrome && npm ci --no-audit --no-fund && npm run build)
scripts/build-app.sh

# DMG: drag-to-install layout.
STAGE="$(mktemp -d)"
cp -R apps/macos/build/Ekagrachit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Ekagrachit $V" -srcfolder "$STAGE" -ov -format UDZO -fs APFS "$OUT/Ekagrachit-$V.dmg" >/dev/null
rm -rf "${STAGE:?}"

# Extension zips.
(cd extensions/chrome/dist && zip -qr -X "$OUT/ekagrachit-chrome-extension-$V.zip" . -x '*.map')
STORE="$(mktemp -d)"
cp -R extensions/chrome/dist/. "$STORE/"
find "$STORE" -name '*.map' -delete
node -e 'const f=process.argv[1]+"/manifest.json";const fs=require("fs");const j=JSON.parse(fs.readFileSync(f));delete j.key;fs.writeFileSync(f,JSON.stringify(j,null,2))' "$STORE"
(cd "$STORE" && zip -qr -X "$OUT/ekagrachit-chrome-web-store-$V.zip" .)
rm -rf "${STORE:?}"

(cd "$OUT" && shasum -a 256 ./*.dmg ./*.zip > SHA256SUMS)
ls -l "$OUT"
