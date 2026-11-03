#!/usr/bin/env bash
# One-time setup for automatic updates. Run on your Mac, from the repository,
# with the GitHub CLI signed in (gh auth login):
#
#   scripts/release/new-update-key.sh
#
# Creates the Ed25519 key that signs every release and stores its private half
# as the repository secret UPDATE_SIGNING_KEY. The key goes straight from
# memory to GitHub; it is never written to disk or committed. The release
# pipeline derives the public half from the secret and builds it into each app.
#
# Run it once. A new key means apps built with the old one can no longer
# verify updates: they would need one manual reinstall. Use --force to rotate.
set -euo pipefail
REPO="${REPO:-thunderboltsid/ekagrachit}"
cd "$(dirname "$0")/../.."
command -v gh >/dev/null || { echo "Install the GitHub CLI (brew install gh) and run gh auth login." >&2; exit 1; }
command -v swift >/dev/null || { echo "Needs swift (xcode-select --install)." >&2; exit 1; }
if gh secret list -R "$REPO" | grep -q '^UPDATE_SIGNING_KEY\b' && [[ "${1:-}" != "--force" ]]; then
  echo "UPDATE_SIGNING_KEY already exists for $REPO. Re-run with --force to replace it (installed apps would then need one manual update)." >&2
  exit 1
fi
KEY="$(swift scripts/release/update-key.swift new)"
printf '%s' "$KEY" | gh secret set UPDATE_SIGNING_KEY -R "$REPO"
PUB="$(UPDATE_SIGNING_KEY="$KEY" swift scripts/release/update-key.swift public)"
unset KEY
echo "Stored UPDATE_SIGNING_KEY for $REPO."
echo "Public key (built into every release from now on): $PUB"
echo "The next push to main releases a version that updates itself."
