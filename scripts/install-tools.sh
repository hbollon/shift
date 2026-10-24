#!/usr/bin/env bash
# Installs the pinned development toolchain into .tools/ (no root needed):
#   - luau (CLI runtime used by the test runner)
#   - luau-lsp (static analysis with the Noctalia type definitions)
#   - noctalia.d.luau (plugin API definitions, also copied to the repo root for editors)
#   - validate-plugins.py (the community-plugins store validator)
#   - git-cliff (changelog and release notes from the Conventional Commits)
# Every download is pinned and checksum-verified. Re-running is a no-op when up to date.
set -euo pipefail

LUAU_VERSION="0.741"
LUAU_SHA256="134dc762ad26232af83e43f98dec03ff6030dd3a4452f9408b9d50ccea025503"
LUAU_LSP_VERSION="1.70.1"
LUAU_LSP_SHA256="1a2ea1ae4f98f8946cefd970a4b54853e11ab4775e6932faa7f60cf920346567"
# noctalia-dev/official-plugins commit providing noctalia.d.luau (plugin_api 32)
OFFICIAL_PLUGINS_REV="d097eb5e197f5714bef80b2185cdf60bb4b8aae8"
NOCTALIA_DEFS_SHA256="cdc8ce17a109ba45ddb47ce241326b95485b1e08222bb3e0943079f5d793beca"
# noctalia-dev/community-plugins commit providing the store validator
COMMUNITY_PLUGINS_REV="453e711cd2a4dc45edff695024e68e0bd704d183"
VALIDATOR_SHA256="e34c6c7f10e9cf545d937f9e9ee027ec7d54cd6f508b0a9faf00a764b2e72245"
GIT_CLIFF_VERSION="2.14.2"
GIT_CLIFF_SHA256="24f397c733add5390fdceee3a2088588ab0d5f944ce00d34cb7029b888cf2db4"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
BIN="$TOOLS/bin"
STAMP="$TOOLS/versions"
WANTED="luau=$LUAU_VERSION luau-lsp=$LUAU_LSP_VERSION official=$OFFICIAL_PLUGINS_REV community=$COMMUNITY_PLUGINS_REV git-cliff=$GIT_CLIFF_VERSION"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WANTED" && -x "$BIN/luau" && -x "$BIN/luau-lsp" && -x "$BIN/git-cliff" ]]; then
  cp -f "$TOOLS/noctalia.d.luau" "$ROOT/noctalia.d.luau"
  echo "tools up to date ($WANTED)"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    LUAU_ASSET="luau-ubuntu.zip"
    LUAU_LSP_ASSET="luau-lsp-linux-x86_64.zip"
    GIT_CLIFF_ASSET="git-cliff-$GIT_CLIFF_VERSION-x86_64-unknown-linux-gnu.tar.gz"
    ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m) (only Linux x86_64 is pinned)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # url sha256 dest
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum --check --quiet - || { echo "checksum mismatch for $1" >&2; exit 1; }
}

mkdir -p "$BIN"

fetch "https://github.com/luau-lang/luau/releases/download/$LUAU_VERSION/$LUAU_ASSET" "$LUAU_SHA256" "$TMP/luau.zip"
unzip -oq "$TMP/luau.zip" luau -d "$BIN"

fetch "https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LUAU_LSP_VERSION/$LUAU_LSP_ASSET" \
  "$LUAU_LSP_SHA256" "$TMP/luau-lsp.zip"
unzip -oq "$TMP/luau-lsp.zip" luau-lsp -d "$BIN"

fetch "https://raw.githubusercontent.com/noctalia-dev/official-plugins/$OFFICIAL_PLUGINS_REV/noctalia.d.luau" \
  "$NOCTALIA_DEFS_SHA256" "$TOOLS/noctalia.d.luau"
cp -f "$TOOLS/noctalia.d.luau" "$ROOT/noctalia.d.luau"

fetch "https://raw.githubusercontent.com/noctalia-dev/community-plugins/$COMMUNITY_PLUGINS_REV/.github/workflows/scripts/validate-plugins.py" \
  "$VALIDATOR_SHA256" "$TOOLS/validate-plugins.py"

fetch "https://github.com/orhun/git-cliff/releases/download/v$GIT_CLIFF_VERSION/$GIT_CLIFF_ASSET" \
  "$GIT_CLIFF_SHA256" "$TMP/git-cliff.tar.gz"
tar -xzf "$TMP/git-cliff.tar.gz" -C "$BIN" --strip-components=1 "git-cliff-$GIT_CLIFF_VERSION/git-cliff"

chmod +x "$BIN/luau" "$BIN/luau-lsp" "$BIN/git-cliff"
echo "$WANTED" > "$STAMP"
echo "installed $WANTED into $TOOLS"
