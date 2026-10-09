#!/usr/bin/env bash
# Runs the community-plugins store validator (pinned by install-tools.sh) against the
# plugin, inside a throwaway git repository that mirrors the community-plugins layout
# (one top-level directory per plugin). Catches store rejections before opening a PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/.tools/validate-plugins.py"
SANDBOX="$ROOT/build/store"

[[ -f "$VALIDATOR" ]] || { echo "missing $VALIDATOR, run 'make tools'" >&2; exit 1; }

rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cp -r "$ROOT/shift" "$SANDBOX/shift"

git -C "$SANDBOX" init -q
git -C "$SANDBOX" add -A
python3 "$VALIDATOR" --root "$SANDBOX"
