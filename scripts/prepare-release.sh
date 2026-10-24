#!/usr/bin/env bash
# Prepares a release: sets the version in shift/plugin.toml, then regenerates catalog.toml and
# CHANGELOG.md (git-cliff, from the Conventional Commits). Commit the result as
# `chore(release): X.Y.Z`, tag that commit `vX.Y.Z` and push the tag: the release workflow
# checks it and publishes the GitHub release.
#
# Usage: scripts/prepare-release.sh X.Y.Z
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 X.Y.Z" >&2; exit 1; }
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "tag v$VERSION already exists" >&2
  exit 1
fi

sed -i -E "s/^(version +)= \"[^\"]*\"/\1= \"$VERSION\"/" "$ROOT/shift/plugin.toml"
grep -qE "^version += \"$VERSION\"$" "$ROOT/shift/plugin.toml" || { echo "could not set the version in plugin.toml" >&2; exit 1; }
"$ROOT/scripts/catalog.py"
"$ROOT/.tools/bin/git-cliff" --config "$ROOT/cliff.toml" --repository "$ROOT" --tag "v$VERSION" \
  --output "$ROOT/CHANGELOG.md" 2>/dev/null

echo "prepared $VERSION: review the diff, commit it as \"chore(release): $VERSION\", then tag it v$VERSION"
