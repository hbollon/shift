#!/usr/bin/env bash
# Fails if plugin code outside shift/lib/host.luau uses the `noctalia` global: host calls
# go through the adapter (spec C10, CONTRIBUTING.md). Comments are ignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

violations="$(find shift -name '*.luau' ! -path shift/lib/host.luau -exec awk '
  { code = $0; sub(/--.*/, "", code) }
  code ~ /(^|[^.A-Za-z0-9_])noctalia\./ { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
' {} +)"

if [[ -n "$violations" ]]; then
  echo "$violations"
  echo "use the host adapter (shift/lib/host.luau) instead of the noctalia global" >&2
  exit 1
fi
echo "no direct noctalia calls outside shift/lib/host.luau"
