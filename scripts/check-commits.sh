#!/usr/bin/env bash
# Checks that commit subjects, and a pull request title when given, follow Conventional Commits
# (CONTRIBUTING.md). Merge commits are skipped.
#
# Usage: scripts/check-commits.sh BASE_REF [TITLE]
set -euo pipefail

PATTERN='^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9._-]+\))?!?: [^ ].*[^.]$'
BASE="${1:?usage: $0 BASE_REF [TITLE]}"
failed=0

check() { # subject, what it is
  if [[ ! "$1" =~ $PATTERN ]]; then
    echo "::error::$2 does not follow Conventional Commits: \"$1\" (see CONTRIBUTING.md)"
    failed=1
  fi
}

while IFS= read -r line; do
  check "${line#* }" "commit ${line%% *}"
done < <(git log --no-merges --format='%h %s' "$BASE..HEAD")

if [[ -n "${2:-}" ]]; then
  check "$2" "the pull request title"
fi

if [[ $failed -eq 0 ]]; then
  echo "commit messages follow Conventional Commits"
fi
exit $failed
