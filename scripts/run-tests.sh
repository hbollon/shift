#!/usr/bin/env bash
# Runs the Luau test suite with the pinned Luau CLI.
#
# Noctalia requires explicit extensions (`require("./lib/x.luau")`) while the Luau CLI
# rejects them (`require("./lib/x")`), so the sources and tests are mirrored into
# build/test with the extension stripped from string-literal requires before running.
#
# Usage: scripts/run-tests.sh [name-filter]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUAU="$ROOT/.tools/bin/luau"
MIRROR="$ROOT/build/test"
FILTER="${1:-}"

[[ -x "$LUAU" ]] || { echo "missing $LUAU, run 'make tools'" >&2; exit 1; }

rm -rf "$MIRROR"
mkdir -p "$MIRROR"
cp -r "$ROOT/shift" "$ROOT/tests" "$MIRROR/"
find "$MIRROR" -name '*.luau' -exec sed -i -E 's/require\("([^"]+)\.luau"\)/require("\1")/g' {} +

mapfile -t specs < <(cd "$MIRROR" && find tests -name '*.spec.luau' | sort)
failed=0
ran=0
for spec in "${specs[@]}"; do
  [[ -n "$FILTER" && "$spec" != *"$FILTER"* ]] && continue
  ran=$((ran + 1))
  echo "▶ $spec"
  if ! (cd "$MIRROR" && "$LUAU" "$spec"); then
    failed=$((failed + 1))
  fi
done

echo
if [[ $ran -eq 0 ]]; then
  echo "no spec matched '${FILTER}'" >&2
  exit 1
fi
if [[ $failed -gt 0 ]]; then
  echo "$failed of $ran spec file(s) failed"
  exit 1
fi
echo "all $ran spec file(s) passed"
