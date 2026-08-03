#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT_FOR_NODE="$ROOT"
if command -v cygpath >/dev/null 2>&1; then
  ROOT_FOR_NODE="$(cygpath -w "$ROOT")"
fi
EXPECTED_VERSION="$(node -e 'console.log(require(process.argv[1]).version)' "$ROOT_FOR_NODE/package.json")"

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
tar -tf "$PACKAGE" | grep '^package/contracts/child-role-loader-v1.json$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/scripts/child_role_loader.py$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/mcp/obsidian-wiki/dist/index.js$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/mcp/obsidian-wiki/dist/atomic_swap.py$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/mcp/obsidian-wiki/dist/wiki_candidate_journal.py$' >/dev/null
tar -tf "$PACKAGE" | grep '^package/mcp/obsidian-wiki/dist/wiki_session_state.py$' >/dev/null
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
tar -tf "$OBSIDIAN_PACKAGE" | grep '^package/dist/wiki_candidate_journal.py$' >/dev/null
tar -tf "$OBSIDIAN_PACKAGE" | grep '^package/dist/wiki_session_state.py$' >/dev/null

npm install --prefix "$TMP/install" "$PACKAGE" >/dev/null
CLI="$TMP/install/node_modules/.bin/grill-adapter"
test "$("$CLI" version)" = "$EXPECTED_VERSION"
"$CLI" validate-package >/dev/null
test -d "$("$CLI" package-root)"
printf 'npm package smoke OK\n'
