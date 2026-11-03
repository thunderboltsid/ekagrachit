#!/usr/bin/env bash
# Sets the product version everywhere it appears.
#   scripts/set-version.sh 1.0.0
set -euo pipefail
V="${1:?usage: set-version.sh X.Y.Z}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
node -e '
const fs = require("fs"); const v = process.argv[1];
for (const f of ["extensions/chrome/manifest.json", "extensions/chrome/package.json"]) {
  const j = JSON.parse(fs.readFileSync(f, "utf8")); j.version = v;
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
}
let plist = fs.readFileSync("apps/macos/Resources/Info.plist", "utf8");
plist = plist.replace(/(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*(<\/string>)/, `$1${v}$2`);
const build = v.split(".").map(Number).reduce((a, n) => a * 100 + n, 0);
plist = plist.replace(/(<key>CFBundleVersion<\/key>\s*<string>)[^<]*(<\/string>)/, `$1${build}$2`);
fs.writeFileSync("apps/macos/Resources/Info.plist", plist);
const host = "apps/macos/Sources/EkagrachitHost/main.swift";
fs.writeFileSync(host, fs.readFileSync(host, "utf8").replace(/let hostVersion = "[^"]*"/, `let hostVersion = "${v}"`));
' "$V"
(cd extensions/chrome && npm install --package-lock-only --silent >/dev/null 2>&1 || true)
echo "Version set to $V"
