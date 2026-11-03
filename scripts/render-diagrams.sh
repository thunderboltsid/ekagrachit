#!/usr/bin/env bash
# Renders docs/diagrams/*.mmd (Mermaid sources) to docs/images/diagrams/*.svg
# with mermaid-cli. The docs embed the rendered SVGs; edit the .mmd and re-run.
#
#   scripts/render-diagrams.sh
#
# Needs Node.js and a Chrome/Chromium binary (set CHROME=/path/to/chrome, or it
# uses Google Chrome on macOS / Playwright's Chromium if present).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/diagrams"
OUT="$ROOT/docs/images/diagrams"
MMDC_VERSION="12.0.0"
mkdir -p "$OUT"

if [[ -z "${CHROME:-}" ]]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           /opt/pw-browsers/chromium-*/chrome-linux64/chrome \
           "$(command -v chromium || true)" "$(command -v google-chrome || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then CHROME="$c"; break; fi
  done
fi
[[ -n "${CHROME:-}" ]] || { echo "No Chrome/Chromium found; set CHROME=/path/to/chrome" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
printf '{"executablePath":"%s","args":["--no-sandbox"]}\n' "$CHROME" > "$TMP/puppeteer.json"
# System font stack: crisp everywhere, and no embedded web font (keeps SVGs ~10 KB).
FONT='-apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif'
printf '{"theme":"neutral","fontFamily":"%s","themeVariables":{"fontFamily":"%s"},"flowchart":{"curve":"basis","wrappingWidth":320}}\n' "$FONT" "$FONT" > "$TMP/config.json"

(cd "$TMP" && PUPPETEER_SKIP_DOWNLOAD=1 npm install --silent --no-audit --no-fund "@mermaid-js/mermaid-cli@$MMDC_VERSION" >/dev/null)
for f in "$SRC"/*.mmd; do
  name="$(basename "$f" .mmd)"
  "$TMP/node_modules/.bin/mmdc" -q -p "$TMP/puppeteer.json" -c "$TMP/config.json" -b white \
    -i "$f" -o "$OUT/$name.svg"
  echo "rendered docs/images/diagrams/$name.svg"
done
