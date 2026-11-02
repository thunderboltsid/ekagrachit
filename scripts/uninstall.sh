#!/usr/bin/env bash
# Removes Ekagrachit.app, its Native Messaging host registrations and its state.
# Remove the Chrome extension itself in chrome://extensions.
#   scripts/uninstall.sh [install-dir]      (default: ~/Applications)
set -euo pipefail
DEST="${1:-$HOME/Applications}"
NAME="io.github.thunderboltsid.ekagrachit"
SUPPORT="${HOME:?}/Library/Application Support"
pkill -x Ekagrachit 2>/dev/null || true
rm -rf "${DEST:?}/Ekagrachit.app"
for browser_dir in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" "BraveSoftware/Brave-Browser"; do
  rm -f "${SUPPORT:?}/${browser_dir:?}/NativeMessagingHosts/${NAME:?}.json"
done
rm -rf "${SUPPORT:?}/Ekagrachit"
defaults delete "$NAME" >/dev/null 2>&1 || true
echo "Ekagrachit removed. Remove the extension in chrome://extensions and the Accessibility entry in System Settings if desired."
