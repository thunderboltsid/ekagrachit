#!/usr/bin/env bash
# Prints the next release tag (vX.Y.Z) for HEAD.
#   Patch bump of the latest vX.Y.Z tag by default.
#   A git trailer "Release: minor" or "Release: major" (its own line in the
#   trailer block at the end of a commit message) in any commit since that tag
#   bumps the minor or major version instead. Only real trailers count:
#   mentioning the words in prose does not.
#   No tags yet: v0.1.0.
set -euo pipefail
last="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
if [[ -z "$last" ]]; then echo "v0.1.0"; exit 0; fi
IFS=. read -r major minor patch <<<"${last#v}"
bumps="$(git log --format='%(trailers:key=Release,valueonly,separator=%x0A)' "$last"..HEAD | tr '[:upper:]' '[:lower:]')"
if grep -qx '[[:space:]]*major[[:space:]]*' <<<"$bumps"; then
  major=$((major + 1)); minor=0; patch=0
elif grep -qx '[[:space:]]*minor[[:space:]]*' <<<"$bumps"; then
  minor=$((minor + 1)); patch=0
else
  patch=$((patch + 1))
fi
echo "v$major.$minor.$patch"
