#!/usr/bin/env bash
# Release notes for TAG (built from REF, default HEAD): the commit subjects
# since the previous vX.Y.Z tag, newest first, and a compare link.
#   scripts/release/notes.sh v0.1.3 [REF]
set -euo pipefail
TAG="${1:?usage: notes.sh vX.Y.Z [ref]}"
REF="${2:-HEAD}"
REPO="${GITHUB_REPOSITORY:-thunderboltsid/ekagrachit}"
prev="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname --merged "$REF" | grep -vx "$TAG" | head -1 || true)"
range="$REF"
[[ -n "$prev" ]] && range="$prev..$REF"
echo "## What's new"
echo
git log --no-merges --format='- %s' "$range"
if [[ -n "$prev" ]]; then
  echo
  echo "**Full changes:** https://github.com/$REPO/compare/$prev...$TAG"
fi
echo
echo "Install: download the DMG, drag Ekagrachit to Applications, open it. Builds are not yet notarized: confirm the first launch in System Settings → Privacy & Security → Open Anyway."
