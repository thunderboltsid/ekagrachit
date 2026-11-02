#!/usr/bin/env bash
# One-step local install on macOS:
#   1. builds the Chrome extension (extensions/chrome/dist)
#   2. builds Ekagrachit.app (unless --app is given) and copies it to ~/Applications
#   3. registers the Native Messaging host for Chrome (and Chromium/Beta/Canary/Brave if present)
#
#   scripts/install.sh [--app /path/to/Ekagrachit.app] [--dest ~/Applications]
#                      [--extension-id <id>] [--skip-extension-build]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"
APP_SRC=""
EXT_ID=""
BUILD_EXT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_SRC="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --extension-id) EXT_ID="$2"; shift 2 ;;
    --skip-extension-build) BUILD_EXT=0; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname)" == "Darwin" ]] || { echo "install.sh must run on macOS" >&2; exit 1; }

if [[ $BUILD_EXT == 1 ]]; then
  if command -v npm >/dev/null; then
    (cd "$ROOT/extensions/chrome" && npm ci --no-audit --no-fund && npm run build)
  elif [[ ! -f "$ROOT/extensions/chrome/dist/manifest.json" ]]; then
    echo "npm not found and extensions/chrome/dist is missing. Install Node.js 22+ (https://nodejs.org) and re-run." >&2
    exit 1
  fi
fi

if [[ -z "$APP_SRC" ]]; then
  "$ROOT/scripts/build-app.sh"
  APP_SRC="$ROOT/apps/macos/build/Ekagrachit.app"
fi
mkdir -p "$DEST"
if pgrep -x Ekagrachit >/dev/null; then
  echo "Quitting the running Ekagrachit…"
  osascript -e 'quit app "Ekagrachit"' >/dev/null 2>&1 || pkill -x Ekagrachit || true
  sleep 1
fi
rm -rf "${DEST:?}/Ekagrachit.app"
cp -R "$APP_SRC" "$DEST/Ekagrachit.app"
xattr -dr com.apple.quarantine "$DEST/Ekagrachit.app" 2>/dev/null || true
HOST_BIN="$DEST/Ekagrachit.app/Contents/MacOS/ekagrachit-host"

# Extension ID: derived from the public key pinned in manifest.json, exactly as Chrome does.
if [[ -z "$EXT_ID" ]]; then
  KEY="$(sed -n 's/.*"key": *"\([^"]*\)".*/\1/p' "$ROOT/extensions/chrome/manifest.json")"
  EXT_ID="$(printf '%s' "$KEY" | openssl base64 -d -A | shasum -a 256 | head -c 32 | tr '0-9a-f' 'a-p')"
fi
echo "Extension ID: $EXT_ID"

NAME="io.github.thunderboltsid.ekagrachit"
MANIFEST=$(cat <<JSON
{
  "name": "$NAME",
  "description": "Ekagrachit native messaging host",
  "path": "$HOST_BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
)
SUPPORT="$HOME/Library/Application Support"
for browser_dir in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" "BraveSoftware/Brave-Browser"; do
  if [[ -d "$SUPPORT/$browser_dir" || "$browser_dir" == "Google/Chrome" ]]; then
    mkdir -p "$SUPPORT/$browser_dir/NativeMessagingHosts"
    printf '%s\n' "$MANIFEST" > "$SUPPORT/$browser_dir/NativeMessagingHosts/$NAME.json"
    echo "Registered native host for $browser_dir"
  fi
done

cat <<MSG

Installed $DEST/Ekagrachit.app

Next steps:
  1. Chrome → chrome://extensions → enable "Developer mode" → "Load unpacked" →
     select $ROOT/extensions/chrome/dist
     (if it was already loaded, click its reload ↻ button)
     The extension ID shown there must be: $EXT_ID
  2. Open Ekagrachit:  open "$DEST/Ekagrachit.app"
  3. Grant Accessibility when asked (System Settings → Privacy & Security → Accessibility).
  4. Click the ◎ icon in the menu bar, paste a URL, choose a duration, Start Focus.

Troubleshooting: scripts/doctor.sh
MSG
