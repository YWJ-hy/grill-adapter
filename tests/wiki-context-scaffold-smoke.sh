#!/usr/bin/env bash
set -euo pipefail

# Schema v5 remains readable during the Obsidian transition, but planning may not create a
# new v5 sidecar. The public scaffold seam accepts only an Obsidian metadata selection and
# produces schema v6; its full contract is covered by obsidian-wiki-context-v6-smoke.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
SCRIPT="${TARGET_INPUT}/scripts/wiki_context_render.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SELECTION="$TMP/legacy.wiki-selection.json"
CONTEXT="$TMP/legacy.wiki-context.json"
printf '%s\n' '{"status":"ok","phase":"plan","wikiPages":[]}' > "$SELECTION"

if python3 "$SCRIPT" "$CONTEXT" --scaffold "$SELECTION" --feature-slug legacy --ticket-source manual --strict >/tmp/wiki-v5-scaffold.out 2>&1; then
  printf 'Expected legacy selection scaffold to fail\n' >&2
  exit 1
fi
grep -q 'schemaVersion 5 is read-only' /tmp/wiki-v5-scaffold.out
if [[ ! -f "$SELECTION" ]]; then
  printf 'Expected rejected legacy selection to remain available for migration\n' >&2
  exit 1
fi

printf '{"schemaVersion":5,"kind":"grill-adapter.wiki-context","wikiPages":[]}' > "$CONTEXT"
python3 "$SCRIPT" "$CONTEXT" --validate-only --strict >/dev/null

printf 'wiki-context scaffold transition smoke test complete\n'
