#!/usr/bin/env bash
# Diagnoses a local Ekagrachit installation. Read-only.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="io.github.thunderboltsid.ekagrachit"
SUPPORT="$HOME/Library/Application Support"
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

echo "Native messaging host manifest (Chrome):"
M="$SUPPORT/Google/Chrome/NativeMessagingHosts/$NAME.json"
if [[ -f "$M" ]]; then
  ok "$M"
  HOST=$(sed -n 's/.*"path": *"\([^"]*\)".*/\1/p' "$M")
  ORIGIN=$(sed -n 's/.*"\(chrome-extension:\/\/[a-p]*\/\)".*/\1/p' "$M")
  if [[ -x "$HOST" ]]; then ok "host binary: $HOST"; else bad "host binary missing or not executable: $HOST"; fi
  echo "    allowed origin: $ORIGIN  (must match the ID shown in chrome://extensions)"
else
  bad "missing — run scripts/install.sh"
fi

echo "Extension build:"
if [[ -f "$ROOT/extensions/chrome/dist/manifest.json" ]]; then ok "$ROOT/extensions/chrome/dist"; else bad "not built — cd extensions/chrome && npm ci && npm run build"; fi

echo "App:"
if pgrep -x Ekagrachit >/dev/null; then ok "Ekagrachit is running"; else bad "Ekagrachit is not running"; fi
SOCK="$SUPPORT/Ekagrachit/bridge.sock"
if [[ -S "$SOCK" ]]; then ok "bridge socket $SOCK"; else bad "bridge socket not found (app not running?)"; fi
if pgrep -f ekagrachit-host >/dev/null; then ok "native host process running (Chrome connected)"; else bad "no native host process (is Chrome running with the extension enabled?)"; fi
if [[ -f "$SUPPORT/Ekagrachit/session.json" ]]; then echo "  • a session is persisted: $SUPPORT/Ekagrachit/session.json"; fi
echo
echo "If the extension popup says 'Native host not installed', re-run scripts/install.sh and reload the extension."
echo "To see Chrome's native messaging errors, quit Chrome and start it from a terminal:"
echo "  /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome --enable-logging=stderr --v=1 2>&1 | grep -i native"
