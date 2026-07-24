#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PACK_JSON="$(
  cd "$ROOT"
  npm pack --json --pack-destination "$TMP" |
    awk 'BEGIN { found = 0 } /^\[/{ found = 1 } found { print }'
)"
TARBALL="$(printf '%s' "$PACK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["filename"])')"
PACKAGE="$TMP/$TARBALL"

test -f "$PACKAGE"
tar -tf "$PACKAGE" | grep -q '^package/bin/grill-adapter.mjs$'
tar -tf "$PACKAGE" | grep -q '^package/.codex-plugin/plugin.json$'
tar -tf "$PACKAGE" | grep -q '^package/mcp/obsidian-wiki/dist/index.js$'
if tar -tf "$PACKAGE" | grep -q '^package/tests/'; then
  echo "published package unexpectedly contains tests/" >&2
  exit 1
fi

npm install --prefix "$TMP/install" "$PACKAGE" >/dev/null
CLI="$TMP/install/node_modules/.bin/grill-adapter"
test "$("$CLI" version)" = "0.2.0"
"$CLI" validate-package >/dev/null
test -d "$("$CLI" package-root)"
printf 'npm package smoke OK\n'
