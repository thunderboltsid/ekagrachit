#!/usr/bin/env bash
# Prints the next release tag (vX.Y.Z) for HEAD.
#   Patch bump of the latest vX.Y.Z tag by default.
#   "[minor]" or "[major]" anywhere in a commit message since that tag bumps
#   the minor or major version instead.
#   No tags yet: v0.1.0.
set -euo pipefail
last="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
if [[ -z "$last" ]]; then echo "v0.1.0"; exit 0; fi
IFS=. read -r major minor patch <<<"${last#v}"
log="$(git log --format='%B' "$last"..HEAD)"
if grep -qi '\[major\]' <<<"$log"; then
  major=$((major + 1)); minor=0; patch=0
elif grep -qi '\[minor\]' <<<"$log"; then
  minor=$((minor + 1)); patch=0
else
  patch=$((patch + 1))
fi
echo "v$major.$minor.$patch"
