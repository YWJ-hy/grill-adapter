#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EXPECTED_VERSION="$(node -p "require('$ROOT/package.json').version")"

PACK_JSON="$(
  cd "$ROOT"
  npm pack --json --pack-destination "$TMP" |
    awk 'BEGIN { found = 0 } /^\[/{ found = 1 } found { print }'
)"
TARBALL="$(printf '%s' "$PACK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["filename"])')"
PACKAGE="$TMP/$TARBALL"

test -f "$PACKAGE"
tar -tf "$PACKAGE" | grep '^package/bin/grill-adapter.mjs$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/.codex-plugin/plugin.json$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/mcp/obsidian-wiki/dist/index.js$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/mcp/obsidian-wiki/dist/atomic_swap.py$' >/dev/null
if tar -tf "$PACKAGE" | grep '^package/tests/' >/dev/null; then
  echo "published package unexpectedly contains tests/" >&2
  exit 1
fi

OBSIDIAN_TMP="$TMP/obsidian-wiki"
mkdir -p "$OBSIDIAN_TMP"
OBSIDIAN_PACK_JSON="$(
  cd "$ROOT/mcp/obsidian-wiki"
  npm pack --json --pack-destination "$OBSIDIAN_TMP" |
    awk 'BEGIN { found = 0 } /^\[/{ found = 1 } found { print }'
)"
OBSIDIAN_TARBALL="$(printf '%s' "$OBSIDIAN_PACK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["filename"])')"
OBSIDIAN_PACKAGE="$OBSIDIAN_TMP/$OBSIDIAN_TARBALL"
test -f "$OBSIDIAN_PACKAGE"
tar -tf "$OBSIDIAN_PACKAGE" | grep '^package/dist/index.js$' >/dev/null
tar -tf "$OBSIDIAN_PACKAGE" | grep '^package/dist/atomic_swap.py$' >/dev/null

npm install --prefix "$TMP/install" "$PACKAGE" >/dev/null
CLI="$TMP/install/node_modules/.bin/grill-adapter"
test "$("$CLI" version)" = "$EXPECTED_VERSION"
"$CLI" validate-package >/dev/null
test -d "$("$CLI" package-root)"
printf 'npm package smoke OK\n'
